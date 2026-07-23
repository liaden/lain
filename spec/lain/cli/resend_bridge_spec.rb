# frozen_string_literal: true

require "json"
require "stringio"

# T18, the M4-2 headline: an edited lain://request actually reaching the
# provider. The bridge is the CLI-owned object between the Neovim resend
# worker (which offers the rebuilt Request as a block) and the Agent's T4
# override slot. It owns the quiescence refusal -- the T4 seam itself PERMITS
# mid-turn interposition, so refusing a mid-flight resend is this bridge's
# mandate -- and the failure UX over RequestOverride#deliver's
# at-least-once-send / exactly-once-commit contract.
RSpec.describe Lain::CLI::ResendBridge do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:override) { Lain::Agent::RequestOverride.new }
  let(:journal) { [] }

  # Deliberately NOT what any render of the Timeline would produce (the T4
  # spec's idiom), so the provider receiving it can only mean the override.
  # max_tokens 512 also lets a flaky provider single out the edited dispatch.
  let(:edited) do
    Lain::Request.new(
      model: "claude-opus-4-8", max_tokens: 512,
      messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "edited by hand" }] }]
    )
  end

  # The chat shape: one journal carries turn_usage (Agent), request_sent
  # (JournalRequests, innermost -- the bytes the provider actually received),
  # and the bridge's own resend_dispatched marker.
  def build_agent(provider)
    stack = Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal:)])
    Lain::Agent.new(provider:, toolset:, context:, request_override: override,
                    journal:, model_middleware: stack)
  end

  def journal_types = journal.map(&:journal_type)

  describe "Scenario: edit, resend, dispatch (idle agent)" do
    it "sends the edited request byte-identically on the next dispatch and settles the run" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first"), text_response("re-answered")])
      agent = build_agent(provider)
      agent.ask("hi")
      original_head = agent.timeline.head_digest

      notice = described_class.new(agent:, journal:).offer { edited }

      expect(provider.last_request).to be(edited)
      expect(Lain::Canonical.dump(provider.last_request.cache_payload))
        .to eq(Lain::Canonical.dump(edited.cache_payload))
      expect(notice).to match(/\Aresend dispatched/)
      expect(agent).to be_done
      expect(override).not_to be_queued
      # The response to the edit committed like any turn, onto the REWOUND
      # head -- and the original head stays reachable in the Store, so this is
      # a speculative fork, never a rewrite.
      expect(agent.timeline.head_digest).not_to eq(original_head)
      expect(agent.timeline.store.key?(original_head)).to be(true)
    end

    it "journals the dispatch distinctly: a resend_dispatched marker TYPE, then the wire's own records" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first"), text_response("re-answered")])
      agent = build_agent(provider)
      agent.ask("hi")

      described_class.new(agent:, journal:).offer { edited }

      # Provenance lives in the record TYPE, never in `extra`: the marker
      # journals attempt-first (before the run), then the dispatch itself is
      # an ORDINARY request_sent/turn_usage pair -- middleware and provider
      # saw an ordinary Request, and the join key is the digest.
      expect(journal_types).to eq(%w[request_sent turn_usage resend_dispatched request_sent turn_usage])
      marker = journal.find { |record| record.is_a?(Lain::Telemetry::ResendDispatched) }
      expect(marker.digest).to eq(edited.digest)
      dispatched = journal.select { |record| record.instance_of?(Lain::Telemetry::RequestSent) }.last
      expect(dispatched.digest).to eq(edited.digest)
    end
  end

  describe "Scenario: mid-flight resend is refused, not queued silently" do
    it "refuses from inside a running turn, names the state, and never forces the rebuild" do
      bridge = nil
      notices = []
      interposer = Class.new(Lain::Tool) do
        define_method(:name) { "interpose" }
        define_method(:description) { "Offers a resend mid-turn." }
        define_method(:input_schema) { { type: :object, properties: {} } }
        define_method(:perform) do |_input, _context|
          notices << bridge.offer { raise "the rebuild must never be forced on a refusal" }
          Lain::Tool::Result.ok("offered")
        end
      end.new
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "interpose", {}]),
                                                      text_response("done")])
      agent = Lain::Agent.new(provider:, toolset: Lain::Toolset.new([interposer]), context:,
                              request_override: override, journal:)
      bridge = described_class.new(agent:, journal:)

      agent.ask("hi")

      expect(notices).to contain_exactly(a_string_matching(/resend refused: agent is mid-turn \(awaiting_tools\)/))
      # Nothing dispatches later surprisingly: the slot was never queued, no
      # marker was journaled, and the run's own two requests are all there are.
      expect(override).not_to be_queued
      expect(journal_types).not_to include("resend_dispatched")
      expect(provider.requests.size).to eq(2)
    end
  end

  describe "an edit that does not rebuild into a Request" do
    it "refuses with the rebuild error, touching neither the slot nor the Timeline" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first")])
      agent = build_agent(provider)
      agent.ask("hi")
      head = agent.timeline.head_digest

      notice = described_class.new(agent:, journal:).offer { raise ArgumentError, "unknown keyword: :bogus" }

      expect(notice).to match(/resend refused: .*does not rebuild.*unknown keyword: :bogus/)
      expect(agent.timeline.head_digest).to eq(head)
      expect(override).not_to be_queued
      expect(journal_types).not_to include("resend_dispatched")
    end
  end

  describe "failure UX over deliver's at-least-once-send / exactly-once-commit contract" do
    it "unqueues the restored edit, says the send may have landed once, and never auto-retries" do
      flaky = Class.new(Lain::Provider::Mock) do
        def complete(request, on_stream_started: nil)
          raise Lain::Error, "simulated 500" if request.max_tokens == 512

          super
        end
      end
      provider = flaky.new(responses: [text_response("first"), text_response("later")])
      agent = build_agent(provider)
      agent.ask("hi")

      notice = described_class.new(agent:, journal:).offer { edited }

      expect(notice).to match(/resend failed: simulated 500/)
      expect(notice).to match(/at-least-once/)
      # deliver restored the unsent edit; the bridge drains it so a later
      # ordinary ask can never send it surprisingly.
      expect(override).not_to be_queued
      # Attempt-first: the marker recorded the dispatch attempt even though
      # the wire raised -- the same reading JournalRequests gives a
      # request_sent with no turn_usage after it.
      expect(journal_types).to include("resend_dispatched")

      agent.ask("again")
      expect(provider.last_request.digest).not_to eq(edited.digest)
    end
  end

  # B1 (BLOCKER): a bridged resend FORKS -- it rewinds below the last exchange
  # and commits the edit's response as a new turn. Under the real chat wiring
  # (a Scribe-backed Chronicle whose turn middleware catches up after every
  # turn), that rewound timeline would raise SessionRecord::Scribe::Diverged at
  # write time -- AFTER the wire was billed -- wedging the chat. The bridge must
  # journal the rewind first, through Chronicle#rewound (T15's record-first
  # seam), so the written chain retreats and the fork commits like any turn.
  describe "B1: a bridged rewind is journaled first, so the live session record never diverges" do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }

    def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
    def record_types = records.map { |record| record["type"] }

    # The chat shape wiring.rb builds: scribe-backed turn middleware (catch_up
    # per turn, Diverged on a rewound chain) plus JournalRequests, one journal.
    def build_chat_shaped_agent(provider, chronicle)
      agent = nil
      Lain::Agent.new(provider:, toolset:, context:, request_override: override,
                      turn_middleware: chronicle.turn_middleware(-> { agent.timeline }),
                      **chronicle.telemetry_kwargs).tap { |built| agent = built }
    end

    it "journals a rewound record, never raises Diverged, and the session stays loadable" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first"), text_response("re-answered")])
      chronicle = Lain::CLI::Chronicle.new(journal:)
      chronicle.start(context:, toolset:)
      agent = build_chat_shaped_agent(provider, chronicle)
      bridge = described_class.new(agent:, journal:, record: chronicle)

      agent.ask("hi")
      chronicle.catch_up(agent.timeline) # the repl's per-ask durability belt

      notice = bridge.offer { edited }

      # The dispatch landed -- no Diverged raised out of the turn phase.
      expect(notice).to match(/\Aresend dispatched/)
      expect(provider.last_request).to be(edited)
      # The rewind was announced as its own record BEFORE the diverging commit.
      expect(record_types).to include("rewound")
      # The written chain extended cleanly, and an ordinary follow-up still
      # records -- the session is not wedged.
      expect { chronicle.catch_up(agent.timeline) }.not_to raise_error
      expect { agent.ask("an ordinary follow-up") }.not_to raise_error
      chronicle.catch_up(agent.timeline)

      # And the file loads: every turn re-commits to its recorded digest and
      # the rewound record folds to the live head.
      loaded = Lain::Bench::Session::Loader.new(journal_io.string.lines).recording
      expect(loaded.timeline.head_digest).to eq(agent.timeline.head_digest)
    end
  end

  # B2 (BLOCKER): the quiescence gate was check-then-act across two drivers --
  # the resend worker thread and the conductor's ask reactor -- with nothing
  # holding the agent still between. The gate is now re-checked under
  # Agent#dispatch_lock, and a busy agent (the lock already held) is a refusal.
  describe "B2: the gate is re-checked under the agent's dispatch lock" do
    it "refuses under the lock even when the state still reads settled (the check-then-act window)" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first")])
      agent = build_agent(provider)
      agent.ask("hi")
      expect(agent).to be_done # the state-only check would PASS here

      held = Thread::Queue.new
      release = Thread::Queue.new
      holder = Thread.new { agent.dispatch_lock.synchronize { held.push(:holding) && release.pop } }
      held.pop # a dispatch now holds the lock, though the state is still :done

      notice = described_class.new(agent:, journal:).offer { edited }

      # Only the lock catches that a dispatch is in flight: an unlocked
      # check-then-act would have dispatched into the busy agent.
      expect(notice).to match(/\Aresend refused: agent is mid-turn \(done\)/)
      expect(override).not_to be_queued
      expect(journal_types).not_to include("resend_dispatched")

      release << :go
      holder.join
    end
  end

  # S1: the failure notice must state exactly what happened. A pre-wire failure
  # (the queue, rewind, or record raised before the run) never left the
  # process, so it must not claim wire ambiguity or a rewind that never
  # happened -- the dishonesty a single static notice produced for the unwired
  # slot.
  describe "S1: notice honesty distinguishes a pre-wire failure from a wire failure" do
    it "a pre-wire failure (unwired slot) claims neither a rewind nor wire ambiguity" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first")])
      stack = Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal:)])
      agent = Lain::Agent.new(provider:, toolset:, context:, journal:,
                              request_override: Lain::Agent::RequestOverride::None, model_middleware: stack)
      agent.ask("hi")
      head = agent.timeline.head_digest

      notice = described_class.new(agent:, journal:).offer { edited }

      expect(notice).to match(/\Aresend failed: no override slot wired/)
      expect(provider.requests.size).to eq(1)
      expect(journal_types).not_to include("resend_dispatched")
      # Honest: nothing moved, nothing sent -- neither false claim appears.
      expect(agent.timeline.head_digest).to eq(head)
      expect(notice).to include("nothing reached the provider")
      expect(notice).not_to include("stays rewound")
      expect(notice).not_to include("may have reached the provider")
    end

    it "a wire failure names the at-least-once ambiguity, because the send may have landed" do
      flaky = Class.new(Lain::Provider::Mock) do
        def complete(request, on_stream_started: nil)
          raise Lain::Error, "simulated 500" if request.max_tokens == 512

          super
        end
      end
      provider = flaky.new(responses: [text_response("first"), text_response("later")])
      agent = build_agent(provider)
      agent.ask("hi")

      notice = described_class.new(agent:, journal:).offer { edited }

      expect(notice).to match(/resend failed: simulated 500/)
      expect(notice).to include("may have reached the provider once")
      expect(notice).to include("at-least-once")
    end
  end

  # S2: a queued resend re-checks the gate at fire time, and the human is told
  # up front an attempt is being made -- fired the instant the gate passes and
  # BEFORE the round trip, and only on a real attempt.
  describe "S2: an upfront attempt notice, at fire time, only when dispatching" do
    it "fires on_attempt before the round trip when the gate passes" do
      order = []
      recording = Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |request, on_stream_started: nil|
          order << :wire
          super(request, on_stream_started:)
        end
      end
      provider = recording.new(responses: [text_response("first"), text_response("re-answered")])
      agent = build_agent(provider)
      agent.ask("hi")
      order.clear

      described_class.new(agent:, journal:).offer(on_attempt: -> { order << :attempt }) { edited }

      expect(order).to eq(%i[attempt wire])
    end

    it "never fires on_attempt on a refusal" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first")])
      agent = build_agent(provider)
      agent.ask("hi")
      held = Thread::Queue.new
      release = Thread::Queue.new
      holder = Thread.new { agent.dispatch_lock.synchronize { held.push(:holding) && release.pop } }
      held.pop

      fired = false
      notice = described_class.new(agent:, journal:).offer(on_attempt: -> { fired = true }) { edited }

      expect(notice).to match(/\Aresend refused/)
      expect(fired).to be(false)

      release << :go
      holder.join
    end
  end

  # The frontend half of the duck, spec'd here so the default suite covers it
  # (the :nvim file only runs under LAIN_NVIM=1): unbridged, the offer is
  # declined WITHOUT forcing the rebuild, so plain --nvim keeps today's pure
  # projection even for an edit that would not rebuild into a Request.
  describe "Lain::Frontend::Neovim::Unbridged (the duck's decline)" do
    it "answers nil and never calls the rebuild block" do
      expect(Lain::Frontend::Neovim::Unbridged.offer { raise "never forced" }).to be_nil
    end
  end
end
