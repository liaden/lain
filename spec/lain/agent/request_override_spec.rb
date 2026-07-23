# frozen_string_literal: true

RSpec.describe Lain::Agent::RequestOverride do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  # The "edited Request R" of the card: deliberately NOT what any render of the
  # Timeline below would produce, so receiving it can only mean the override.
  let(:edited) do
    Lain::Request.new(
      model: "claude-opus-4-8", max_tokens: 512,
      messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "edited by hand" }] }]
    )
  end

  # Two dispatches in one run: the overridden one, then the rendered one. A
  # method, not a let: Provider::Mock consumes the array it is handed, so each
  # run needs its own.
  def responses = [tool_response(["tu_1", "echo", { "text" => "a" }]), text_response("settled")]

  describe "the slot" do
    it "resolves to the render when nothing is queued" do
      expect(described_class.new.resolve { :rendered }).to eq(:rendered)
    end

    it "resolves the queued request without invoking the render at all" do
      override = described_class.new.queue(edited)
      expect(override.resolve { raise "render must not run under an override" }).to be(edited)
    end

    it "is one-shot: consuming empties the slot" do
      override = described_class.new.queue(edited)
      override.resolve { raise }

      expect(override).not_to be_queued
      expect(override.resolve { :rendered }).to eq(:rendered)
    end

    it "last write wins when queued twice before a dispatch" do
      override = described_class.new.queue(edited).queue(edited.with(max_tokens: 99))
      expect(override.resolve { raise }.max_tokens).to eq(99)
    end
  end

  describe "thread safety (panel probe 1)" do
    # T18's ResendBridge queues from the frontend thread while the loop runs in
    # its reactor, so a #queue racing the consume is the shipped topology. The
    # consume boundary is `@request.tap { @request = nil }` inside the slot --
    # this spec hooks the queued object's #tap to stand exactly in that window
    # and queue a second edit from another thread. Unsynchronized, the consume's
    # nil-write lands after the concurrent queue and silently wipes it (probe
    # 1's finding); under the slot's Mutex the queuing thread blocks until the
    # consume completes, so the edit survives for the next dispatch. If the
    # slot's consume ever stops going through #tap, move this hook with it.
    it "never loses an edit queued concurrently with the consume" do
      slot = described_class.new
      second = edited.with(max_tokens: 99)
      queuer = nil
      # A stand-in for R: the slot holds the edit opaquely, and a Request is
      # frozen too deep to carry the instrumented #tap.
      doctored = Object.new
      doctored.define_singleton_method(:tap) do |&block|
        queuer = Thread.new { slot.queue(second) }
        queuer.join(0.2) # times out when the queuer is (correctly) locked out
        block.call(self)
        self
      end

      taken = slot.queue(doctored).resolve { :rendered }
      queuer.join

      expect(taken).to be(doctored)
      expect(slot).to be_queued
      expect(slot.resolve { :rendered }).to be(second)
    end

    it "loses nothing under a real-thread stress race" do
      second = edited.with(max_tokens: 99)
      losses = 500.times.count do
        slot = described_class.new.queue(edited)
        gate = Queue.new
        thread = Thread.new do
          gate.pop
          slot.queue(second)
        end
        gate << :go
        got = slot.resolve { :rendered }
        thread.join
        got.equal?(edited) && !slot.queued?
      end

      expect(losses).to eq(0)
    end
  end

  describe "consume-on-success (panel probe 3)" do
    it "restores the unsent edit when the overridden round trip raises, so a retry sends R" do
      override = described_class.new.queue(edited)
      flaky = Class.new(Lain::Provider::Mock) do
        def complete(request, on_stream_started: nil)
          unless @tripped
            @tripped = true
            raise Lain::Error, "simulated transient 429"
          end
          super
        end
      end
      provider = flaky.new(responses: [text_response("done")])
      agent = Lain::Agent.new(provider:, toolset:, context:, request_override: override)

      expect { agent.ask("hi") }.to raise_error(Lain::Error, /simulated transient 429/)
      expect(override).to be_queued

      agent.run
      expect(provider.last_request).to be(edited)
      expect(override).not_to be_queued
    end

    it "does not clobber a fresher edit queued during the failed round trip: last write still wins" do
      newer = edited.with(max_tokens: 99)
      override = described_class.new.queue(edited)
      interposing = Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |_request, on_stream_started: nil| # rubocop:disable Lint/UnusedBlockArgument
          override.queue(newer)
          raise Lain::Error, "boom mid-flight"
        end
      end
      agent = Lain::Agent.new(provider: interposing.new(responses: []), toolset:, context:,
                              request_override: override)

      expect { agent.ask("hi") }.to raise_error(Lain::Error, /boom mid-flight/)
      expect(override.resolve { :rendered }).to be(newer)
    end
  end

  describe "mid-turn interposition (panel probe 2): permitted here, refused at T18's bridge" do
    # Orchestrator decision: this seam PERMITS a mid-turn queue -- refusing a
    # mid-flight resend is T18's ResendBridge's mandate, not the slot's. This
    # spec pins the splice so the permitted behavior is a documented contract:
    # an edit queued during tool execution applies to the very next dispatch of
    # the SAME run (the one that would have delivered the tool_results), so the
    # results commit to the Timeline but never reach the provider. Queuers own
    # agent quiescence; the sanctioned resend entry is rewind + queue + run.
    it "a queue from inside tool execution splices into the tool_results dispatch" do
      override = described_class.new
      request = edited
      tool = Class.new(Lain::Tool) do
        define_method(:name) { "queue_override" }
        define_method(:description) { "Queues a request override mid-turn." }
        define_method(:input_schema) { { type: :object, properties: {} } }
        define_method(:perform) do |_input, _context|
          override.queue(request)
          Lain::Tool::Result.ok("queued")
        end
      end.new
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "queue_override", {}]),
                                                      text_response("responding to R")])
      agent = Lain::Agent.new(provider:, toolset: Lain::Toolset.new([tool]), context:,
                              request_override: override)

      agent.ask("hi")

      expect(provider.requests.last).to be(edited)
      results_turn = agent.timeline.to_a[2]
      expect(results_turn.role).to eq("user")
      expect(results_turn.content.map { |block| block["type"] }).to eq(["tool_result"])
      sent = provider.requests.flat_map(&:messages).flat_map { |m| m["content"].map { |b| b["type"] } }
      expect(sent).not_to include("tool_result")
    end
  end

  describe "Scenario: one-shot override" do
    it "sends R byte-identically, renders from the Timeline next, and cannot apply twice" do
      override = described_class.new.queue(edited)
      provider = Lain::Provider::Mock.new(responses:)
      agent = Lain::Agent.new(provider:, toolset:, context:, request_override: override)

      agent.ask("hi")

      first, second = provider.requests
      expect(first).to be(edited)
      expect(Lain::Canonical.dump(first.cache_payload)).to eq(Lain::Canonical.dump(edited.cache_payload))
      # The following iteration is a plain render of the Timeline: the user turn
      # is the asked "hi", not R's edited text, and R leaves no residue.
      expect(second.messages.first["content"].first["text"]).to eq("hi")
      expect(second.messages.map { |m| m["role"] }).to eq(%w[user assistant user])
      expect(second.digest).not_to eq(edited.digest)
      expect(override).not_to be_queued
    end
  end

  describe "Scenario: commit semantics unchanged" do
    def run(events, request_override:)
      provider = Lain::Provider::Mock.new(responses:)
      agent = Lain::Agent.new(provider:, toolset:, context:, journal: events, request_override:)
      agent.ask("hi")
      agent
    end

    it "commits the response to R like any turn and emits no new telemetry" do
      control_events = []
      control = run(control_events, request_override: described_class::None)
      events = []
      agent = run(events, request_override: described_class.new.queue(edited))

      # The Timeline records the same turns with the same digests as a run that
      # never overrode: the turn digest is over the canonical response, and the
      # override leaves nothing behind in the record.
      expect(agent.timeline.head_digest).to eq(control.timeline.head_digest)
      # No new telemetry, at PAYLOAD depth (panel probe 5): class-level equality
      # would miss an override flag smuggled into TurnUsage or a digest drift.
      # Journaling an overridden dispatch is T18's scope.
      expect(events).to eq(control_events)
    end
  end

  describe "RequestOverride::None" do
    it "is the Agent default, reachable at Agent#request_override (T18's access path)" do
      provider = Lain::Provider::Mock.new(responses: [text_response])
      agent = Lain::Agent.new(provider:, toolset:, context:)

      expect(agent.request_override).to be(described_class::None)
    end

    it "always renders, through both halves of the duck" do
      expect(described_class::None.resolve { :rendered }).to eq(:rendered)
      expect(described_class::None.deliver(render: -> { edited }) { |request| request }).to be(edited)
      expect(described_class::None).not_to be_queued
    end

    it "refuses to queue, loudly: discarding an edit in silence is not a Null behavior" do
      expect { described_class::None.queue(edited) }.to raise_error(Lain::Error, /request_override/)
    end
  end
end
