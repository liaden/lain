# frozen_string_literal: true

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

      records = turn_usage_records
      expect(records.size).to eq(1)
      expect(records.first).to include(
        "digest" => a.timeline.head_digest,
        "model" => "claude-opus-4-8",
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 10, "output_tokens" => 5,
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
    # counted twice (see Event::TurnUsage: the digest is a join key).
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

  describe "state machine" do
    it "starts awaiting_user" do
      expect(agent(text_response).state).to eq(:awaiting_user)
    end

    it "exposes every declared state" do
      expect(described_class::STATES)
        .to contain_exactly(:awaiting_user, :awaiting_model, :awaiting_tools,
                            :awaiting_approval, :done, :failed)
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
end
