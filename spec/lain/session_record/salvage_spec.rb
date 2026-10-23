# frozen_string_literal: true

require "json"
require "stringio"

# Recovering a paid-for-but-uncommitted response from the response WAL
# when a session resumes open. `frames` are built through the REAL
# Provider::ResponseWal / Provider::Anthropic pair wherever fidelity to
# production bytes matters (response_wal_spec's own precedent), rather than
# hand-authored fixtures -- what proves this class works is that it reassembles
# EXACTLY what the live streaming path would have produced.
# A chat provider that refuses while the history is in the prompt, the way the
# handoff seam's recorded one does, and answers the handoff schema when asked.
module SalvageHandoff
  ANSWER = { "goal" => "finish the parser", "progress" => "lexer done", "files_and_decisions" => "lexer.rb",
             "open_todos" => "parser", "next_step" => "write parser.rb" }.freeze

  class Recorded
    class Refusal < Lain::Error
      include Lain::WindowExceeded
    end

    attr_reader :requests

    def initialize = @requests = []

    def complete(request)
      return answer(JSON.generate(ANSWER)) if Lain::Canonical.dump(request.messages).include?("no longer fits")

      @requests << request
      raise Refusal.new("too big", prompt_tokens: 9000, window_tokens: 8192, source: "ollama") if overflowing?(request)

      answer("settled")
    end

    def supports?(_capability) = false

    def cache_profile = Lain::CacheProfile::NO_CACHING

    private

    # The history alone fills the window until a handoff replaces it.
    def overflowing?(request) = request.messages.size >= 5

    def answer(text)
      Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn,
                         usage: Lain::Usage.new(input_tokens: 30, output_tokens: 2))
    end
  end
end

RSpec.describe Lain::SessionRecord::Salvage do
  around { |example| Dir.mktmpdir("salvage") { |dir| @wal_path = File.join(dir, "session.wal") and example.run } }

  def text(body) = [{ "type" => "text", "text" => body }]

  let(:timeline) { CoreGraph.timeline.commit(role: :user, content: text("hi")) }

  let(:canned) do
    Lain::Response.new(id: "msg_1", model: "claude-opus-4-8", stop_reason: :end_turn,
                       content: text("recovered!"), usage: Lain::Usage.new(input_tokens: 10, output_tokens: 4))
  end

  def request_sent(digest)
    { "type" => "request_sent", "digest" => digest, "payload" => {}, "stream" => true, "extra" => {} }
  end

  def turn_record(role)
    { "type" => "turn", "digest" => "blake3:#{role}", "role" => role, "content" => text(role), "parent" => nil,
      "meta" => {} }
  end

  def turn_usage(digest)
    { "type" => "turn_usage", "digest" => digest, "model" => "m", "stop_reason" => "end_turn", "usage" => {} }
  end

  def anthropic_request(**overrides)
    Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64,
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  def stub_stream(body, status: 200)
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status:, body:, headers: { "Content-Type" => "text/event-stream" })
  end

  # Spools ONE response through the real Anthropic provider, so the WAL
  # frame left behind is byte-for-byte what a live crashed run would have
  # written (response_wal_spec's own "spools a streamed response verbatim"
  # precedent) -- the highest-fidelity input this spec can hand Salvage.
  def spool(response, request = anthropic_request)
    stub_stream(AnthropicSSE.body(response))
    provider = Lain::Provider::Anthropic.new(spool: Lain::Provider::ResponseWal.new(@wal_path), api_key: "test")
    provider.complete(request)
    request.digest
  end

  def frames = Lain::Provider::ResponseWal.new(@wal_path).frames

  describe "a complete uncommitted response" do
    it "assembles a Response equal to the original and makes no provider call of its own" do
      digest = spool(canned)

      outcome = described_class.new(entries: [request_sent(digest)], frames:, timeline:).call

      expect(outcome).to be_recovered
      expect(outcome.request_digest).to eq(digest)
      expect(outcome.response.content).to eq(canned.content)
      expect(outcome.response.stop_reason).to eq(canned.stop_reason)
      expect(outcome.response.usage).to eq(canned.usage)
    end

    it "targets the agent's request when a summarizer's was journaled after it" do
      digest = spool(canned)
      summarizer = request_sent("blake3:summarizer").merge("requester" => "summarizer")

      outcome = described_class.new(entries: [request_sent(digest), summarizer], frames:, timeline:).call

      expect(outcome).to be_recovered
      expect(outcome.request_digest).to eq(digest)
    end

    it "is not settled by a spawned child's payment journaled after it" do
      digest = spool(canned)
      child = turn_usage("blake3:child").merge("spawn" => "blake3:spawn")

      outcome = described_class.new(entries: [request_sent(digest), child], frames:, timeline:).call

      expect(outcome).to be_recovered
    end

    # The recovered turn's spend is the whole reason this class exists, and it
    # was the third hand-written copy of the same four-key decode. One decoder
    # now, so a key cannot drift only on the path nobody was watching.
    it "decodes the recovered usage through Usage.from_anthropic_wire" do
      # Spool FIRST: the live Provider::Anthropic that writes the frame decodes
      # through the same method, so a spy armed before it would be satisfied by
      # the provider's call and prove nothing about Salvage.
      digest = spool(canned)
      allow(Lain::Usage).to receive(:from_anthropic_wire).and_call_original

      outcome = described_class.new(entries: [request_sent(digest)], frames:, timeline:).call

      expect(Lain::Usage).to have_received(:from_anthropic_wire)
      expect(outcome.response.usage).to eq(canned.usage)
    end

    it "commits the reassembled content as the new assistant head, onto the given Timeline" do
      digest = spool(canned)

      outcome = described_class.new(entries: [request_sent(digest)], frames:, timeline:).call

      expect(outcome.timeline.head_digest).not_to eq(timeline.head_digest)
      expect(outcome.turn.role).to eq("assistant")
      expect(outcome.turn.content).to eq(canned.content)
      expect(outcome.turn.parent).to eq(timeline.head_digest)
    end

    it "survives multibyte content, proving the ASCII-8BIT WAL bytes are force-encoded before parsing" do
      multibyte = Lain::Response.new(stop_reason: :end_turn, content: text("café ☃"))
      digest = spool(multibyte)

      outcome = described_class.new(entries: [request_sent(digest)], frames:, timeline:).call

      expect(outcome.response.text).to eq("café ☃")
    end
  end

  # Panel blocker (Torvalds): a second SIGKILL between the `turn` write and
  # the `session_closed` write leaves a file whose request_sent is STILL
  # unanswered (no turn_usage -- salvage's own records don't count) but whose
  # Timeline ALREADY carries the recovered turn as head. Re-resuming must
  # recognize that and complete the anchor only, never commit a second copy.
  describe "idempotency: re-resuming after the turn landed but before the close did" do
    it "does not commit a second copy when the given Timeline already ends with the recovered content" do
      digest = spool(canned)
      first = described_class.new(entries: [request_sent(digest)], frames:, timeline:).call
      expect(first).to be_recovered

      # The second call gets the SAME unanswered request_sent (no turn_usage
      # was ever added) and the SAME frames, but a Timeline that already
      # carries the recovery -- exactly what a fresh Loader rebuild of the
      # partially-appended file would hand it.
      second = described_class.new(entries: [request_sent(digest)], frames:, timeline: first.timeline).call

      expect(second).to be_recovered
      expect(second.newly_committed?).to be(false)
      expect(second.timeline.head_digest).to eq(first.timeline.head_digest)
      expect(second.timeline.to_a.map(&:digest)).to eq(first.timeline.to_a.map(&:digest))
    end

    it "still commits fresh when the given Timeline predates the recovery (crash before the turn write)" do
      digest = spool(canned)

      outcome = described_class.new(entries: [request_sent(digest)], frames:, timeline:).call

      expect(outcome).to be_recovered
      expect(outcome.newly_committed?).to be(true)
    end
  end

  # A prompt's turn record lands only once its answer commits, so a kill
  # mid-stream leaves the prompt in the request_sent payload alone.
  describe "the prompt the crash lost" do
    let(:answered) { timeline.commit(role: :assistant, content: text("hello")) }
    let(:workspace) { Lain::Workspace.new(reminders: ["no todos"]) }

    def sent(request) = Lain::Telemetry::RequestSent.from(request).to_journal

    def render(over) = CoreGraph.context.render(timeline: over, toolset: Lain::Toolset.new, workspace:)

    it "rebuilds the prompt from the payload tail, without the cache and workspace markers, under the answer" do
      asked = answered.commit(role: :user, content: text("say iota"))
      request = render(asked)
      spool(canned, request)

      outcome = described_class.new(entries: [sent(request)], frames:, timeline: answered).call

      uninterrupted = asked.commit(role: :assistant, content: canned.content)
      expect(outcome.timeline.to_a.map(&:digest)).to eq(uninterrupted.to_a.map(&:digest))
    end

    it "rebuilds no user turn over a tool continuation, whose results are already on record" do
      call = { "type" => "tool_use", "id" => "tu_1", "name" => "echo", "input" => {} }
      result = { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => "ok" }
      continued = timeline.commit(role: :assistant, content: [call]).commit(role: :user, content: [result])
      request = render(continued)
      spool(canned, request)

      outcome = described_class.new(entries: [sent(request)], frames:, timeline: continued).call

      expect(outcome.turn.parent).to eq(continued.head_digest)
      expect(outcome.turn.digest).to eq(continued.commit(role: :assistant, content: canned.content).head_digest)
    end

    # The original run's own request and chain, so the rebuild is judged
    # against what a chat really sends and commits.
    def asked_for_real(timeline: CoreGraph.timeline, mailbox: Lain::Context::Mailbox::Null)
      provider = Lain::Provider::Mock.new(responses: [canned])
      agent = Lain::Agent.new(provider:, context: CoreGraph.context, toolset: Lain::Toolset.new, timeline:, mailbox:)
      yield mailbox if block_given?
      agent.ask("say iota")
      [provider.requests.first, agent.timeline]
    end

    # The answer's link to the note it folded is not in the payload, so only
    # the prompt comes back at its original digest.
    it "rebuilds the prompt a pending human note was folded into, without the note" do
      mailbox = Lain::Context::Mailbox::Live.new(recipient: Lain::EventLog::ChainWriter.method(:correlation_of),
                                                 observer: ->(_event) {})
      request, original = asked_for_real(mailbox:) { |box| box.post(from: "human", text: "also, be brief") }
      spool(canned, request)

      outcome = described_class.new(entries: [sent(request)], frames:, timeline: CoreGraph.timeline).call

      prompt, answer = outcome.timeline.to_a
      expect(prompt.digest).to eq(original.to_a.first.digest)
      expect(answer.content).to eq(canned.content)
      expect(answer.causal_parents).to be_empty
    end

    it "keeps a typed prompt that only resembles a folded note" do
      typed = "<mailbox>\nnot a note\n</mailbox>"
      asked = answered.commit(role: :user, content: text(typed))
      request = render(asked)
      spool(canned, request)

      outcome = described_class.new(entries: [sent(request)], frames:, timeline: answered).call

      expect(outcome.timeline.to_a[-2].digest).to eq(asked.head_digest)
    end

    it "rebuilds the cancellation a resume answered in memory, under the prompt, at the original digests" do
      call = { "type" => "tool_use", "id" => "tu_1", "name" => "echo", "input" => {} }
      stranded = timeline.commit(role: :assistant, content: [call])
      request, original = asked_for_real(timeline: stranded)
      spool(canned, request)

      outcome = described_class.new(entries: [sent(request)], frames:, timeline: stranded).call

      expect(outcome.timeline.to_a.map(&:digest)).to eq(original.to_a.map(&:digest))
    end

    # A handoff retry and a compacted render both send user messages the
    # Timeline never held ahead of the ask; only the ask is the agent's own.
    describe "over derived messages" do
      let(:journal) { Lain::Journal.new(io: StringIO.new) }

      def handoff_tier(provider)
        definition = Lain::Oracle::Handoff.definition
        inner = Lain::Oracle::Model.new(definition:, provider:, model: "qwen3:4b", max_tokens: 512)
        Lain::Oracle::Recorded::Journaling.new(inner:, definition:, journal:)
      end

      def handoff_source(provider)
        Lain::Compaction::Source.new(
          need: Lain::Compaction::Need.new(byte_threshold: 1_000_000),
          cold: Lain::Compaction::Cold.new(cache_profile: Lain::CacheProfile::NO_CACHING, journal:),
          hard_cap: 1_000_000, keep_last: 20, journal:,
          fallback: Lain::Compaction::Source::Fallback.new(tier: -> { handoff_tier(provider) }),
          context_window: Lain::ContextWindow.new(windows: { "qwen3" => 8192 })
        )
      end

      it "rebuilds only the ask of a handoff retry" do
        provider = SalvageHandoff::Recorded.new
        source = handoff_source(provider)
        budget = Lain::Middleware::RequestBudget.new(journal:, compaction: source)
        chat = Lain::Agent.new(provider:, toolset: Lain::Toolset.new([]), journal:,
                               context: Lain::Context.new(model: "qwen3:4b", max_tokens: 64, system: "s"),
                               session: Lain::Session.new(journal:), pipeline_source: source,
                               model_middleware: Lain::Middleware::Stack.new([budget]))
        2.times { |i| chat.ask("question #{i}: #{"the lazy dog slept. " * 20}") }
        on_disk = chat.timeline
        chat.ask("so what is left to do?")
        retried = provider.requests.last
        spool(canned, retried)

        outcome = described_class.new(entries: [sent(retried)], frames:, timeline: on_disk).call

        expect(retried.messages.map { |message| message["role"] }).to eq(%w[user user])
        expect(outcome.committed.map(&:role)).to eq(%w[user assistant])
        expect(outcome.committed.first.digest).to eq(chat.timeline.to_a[-2].digest)
      end

      it "rebuilds only the ask under a compacted render" do
        history = timeline.commit(role: :assistant, content: text("first answer " * 50))
        compact = lambda { |workspace|
          Lain::Context::Compact.new(threshold: 10, keep_last: 1, summarizer: ->(_messages) { "EARLIER" }) >>
            Lain::Context::Reminder.new(workspace:) >> Lain::Context::CacheBreakpoints.new
        }
        context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64, system: "s", pipeline: compact)
        provider = Lain::Provider::Mock.new(responses: [canned])
        agent = Lain::Agent.new(provider:, context:, toolset: Lain::Toolset.new, timeline: history, workspace:)
        agent.ask("say iota")
        request = provider.requests.first
        spool(canned, request)

        outcome = described_class.new(entries: [sent(request)], frames:, timeline: history).call

        expect(request.messages.map { |message| message["role"] }).to eq(%w[user user])
        expect(outcome.timeline.to_a.map(&:digest)).to eq(agent.timeline.to_a.map(&:digest))
      end
    end

    # A user head already holds the request's last message, however a render
    # reshaped it; only a prompt asked over tool results is new.
    describe "over a user head" do
      let(:reply) { Lain::Response.new(content: text("framed"), stop_reason: :end_turn) }

      def salvaged(request, on_disk)
        spool(reply, request)
        described_class.new(entries: [sent(request)], frames:, timeline: on_disk).call
      end

      def bare_context(pipeline: nil)
        Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64, system: "s", pipeline:)
      end

      it "commits only the answer to a resend whose edited message never became a turn" do
        provider = Lain::Provider::Mock.new(responses: [Lain::Response.new(content: text("a1"), stop_reason: :end_turn),
                                                        reply])
        override = Lain::Agent::RequestOverride.new
        agent = Lain::Agent.new(provider:, context: bare_context, toolset: Lain::Toolset.new,
                                timeline: CoreGraph.timeline, request_override: override)
        agent.ask("p")
        agent.rewind(1)
        on_disk = agent.timeline
        first = provider.requests.first
        override.queue(Lain::Request.new(model: first.model, system: first.system, max_tokens: first.max_tokens,
                                         messages: [{ "role" => "user", "content" => text("p, edited in nvim") }]))
        agent.run

        outcome = salvaged(provider.requests.last, on_disk)

        expect(outcome.timeline.to_a.map(&:digest)).to eq(agent.timeline.to_a.map(&:digest))
      end

      it "commits only the answer to a tool continuation whose duplicate call the render deduped" do
        call = ->(id) { { "type" => "tool_use", "id" => id, "name" => "bash", "input" => { "command" => "echo hi" } } }
        twice = Lain::Response.new(content: [call.call("tu_1"), call.call("tu_2")], stop_reason: :tool_use)
        provider = Lain::Provider::Mock.new(responses: [twice, reply])
        pipeline = lambda { |workspace|
          Lain::Context::Reminder.new(workspace:) >> Lain::Context::DedupeToolCalls.new >>
            Lain::Context::CacheBreakpoints.new
        }
        agent = Lain::Agent.new(provider:, context: bare_context(pipeline:), timeline: CoreGraph.timeline,
                                toolset: Lain::Toolset.new([Lain::Tools::Bash.new]))
        agent.ask("run echo twice")

        outcome = salvaged(provider.requests.last, agent.timeline.checkout(agent.timeline.head.parent))

        expect(outcome.timeline.to_a.map(&:digest)).to eq(agent.timeline.to_a.map(&:digest))
      end

      it "commits only the answer to a stranded prompt folded with a typed prompt shaped like a note" do
        provider = Lain::Provider::Mock.new(responses: [reply])
        agent = Lain::Agent.new(provider:, context: bare_context, toolset: Lain::Toolset.new,
                                timeline: CoreGraph.timeline.commit(role: :user, content: text("first")))
        agent.ask("<mailbox>\nnot a note\n</mailbox>")

        outcome = salvaged(provider.requests.last, agent.timeline.checkout(agent.timeline.head.parent))

        expect(outcome.timeline.to_a.map(&:digest)).to eq(agent.timeline.to_a.map(&:digest))
      end
    end

    # A resume answers a stranded call in memory, so the cancellation is a turn
    # the file lacks; only a message that answers the call is that turn.
    describe "over a stranded call" do
      let(:call) { { "type" => "tool_use", "id" => "tu_1", "name" => "echo", "input" => {} } }
      let(:stranded) { timeline.commit(role: :assistant, content: [call]) }
      let(:cancelled) { Lain::Tool::Cancellation.new(stranded.head, kind: :unknown).blocks }

      def salvaged(request)
        spool(canned, request)
        described_class.new(entries: [sent(request)], frames:, timeline: stranded).call
      end

      def request_of(*messages) = Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64, messages:)

      it "mints the cancellation when the message before the prompt is a derived one" do
        outcome = salvaged(request_of({ "role" => "user", "content" => text("a handoff document") },
                                      { "role" => "user", "content" => text("go on") }))

        expect(outcome.committed.map(&:content)).to eq([cancelled, text("go on"), canned.content])
      end

      it "mints the cancellation when the request holds the prompt alone" do
        outcome = salvaged(request_of({ "role" => "user", "content" => text("go on") }))

        expect(outcome.committed.map(&:content)).to eq([cancelled, text("go on"), canned.content])
      end
    end

    it "keeps a note-shaped block that carries a key a folded note never has" do
      shaped = { "type" => "text", "text" => "<mailbox>\nhuman | hi\n</mailbox>", "citations" => [] }
      request = Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64,
                                  messages: [{ "role" => "user", "content" => [*text("say iota"), shaped] }])
      spool(canned, request)

      outcome = described_class.new(entries: [sent(request)], frames:, timeline: answered).call

      expect(outcome.committed.first.content).to eq([*text("say iota"), shaped])
    end

    it "commits only the assistant turn when an older file's payload is empty" do
      digest = spool(canned)

      outcome = described_class.new(entries: [request_sent(digest)], frames:, timeline: answered).call

      expect(outcome.timeline.to_a.map(&:role)).to eq(%w[user assistant assistant])
      expect(outcome.turn.parent).to eq(answered.head_digest)
    end
  end

  describe "the retry ruling: only the LAST frame per digest is real" do
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

    def spool_through(stub)
      provider = Lain::Provider::Anthropic.new(spool: Lain::Provider::ResponseWal.new(@wal_path), api_key: "test")
      stub.call
      provider.complete(anthropic_request)
    rescue Lain::Error
      nil
    ensure
      WebMock.reset!
    end

    def answered
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: AnthropicSSE.body(canned), headers: { "Content-Type" => "text/event-stream" })
    end

    # The render is pure, so a prompt re-asked over the head a rewind restored
    # has the digest the answered one had. The frame that answered it is still
    # in the log, and the last round trip for that digest is the one that
    # failed: recovering the old answer would commit it onto a head that no
    # longer holds the question.
    it "recovers nothing when an older complete frame is followed by a failed round trip for the same digest" do
      spool_through(-> { answered })
      spool_through(-> { stub_request(:post, "https://api.anthropic.com/v1/messages").to_raise(Errno::ECONNREFUSED) })

      outcome = described_class.new(entries: [request_sent(anthropic_request.digest)], frames:, timeline:).call

      expect(frames.to_a.map(&:complete?)).to eq([true, false, false, false])
      expect(outcome).not_to be_recovered
      expect(outcome.request_digest).to eq(anthropic_request.digest)
    end

    # The same join, on the one refusal that already withdrew a prompt before
    # pre-wire failures did: ollama's over-window 400 over a digest an earlier
    # round trip answered.
    it "recovers nothing when the later round trip was refused for not fitting the context" do
      request = Lain::Request.new(model: "qwen3:4b", max_tokens: 64, messages: [{ role: "user", content: "hi" }])
      ollama = Lain::Provider::Ollama.new(config: zero_retry_config, spool: Lain::Provider::ResponseWal.new(@wal_path))
      reply = { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "old" }, "done" => true,
                "done_reason" => "stop", "prompt_eval_count" => 5, "eval_count" => 1 }
      ndjson = "#{JSON.generate(reply)}\n"
      refusal = { "error" => { "type" => "exceed_context_size_error", "n_prompt_tokens" => 9_000, "n_ctx" => 8192 } }
      stub_request(:post, %r{/api/chat})
        .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" }, body: ndjson)
        .then.to_return(status: 400, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate("error" => JSON.generate(refusal)))
      ollama.complete(request)
      expect { ollama.complete(request) }.to raise_error(Lain::WindowExceeded)

      outcome = described_class.new(entries: [request_sent(request.digest)], frames:, timeline:).call

      expect(frames.to_a.map(&:complete?)).to eq([true, false])
      expect(outcome).not_to be_recovered
    end

    it "ignores an earlier aborted attempt and recovers only the retried attempt's content" do
      request = anthropic_request
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_raise(Faraday::ConnectionFailed)
        .to_return(status: 200, body: AnthropicSSE.body(canned), headers: { "Content-Type" => "text/event-stream" })
      provider = Lain::Provider::Anthropic.new(spool: Lain::Provider::ResponseWal.new(@wal_path), api_key: "test")
      provider.complete(request)

      outcome = described_class.new(entries: [request_sent(request.digest)], frames:, timeline:).call

      expect(frames.to_a.map(&:complete?)).to eq([false, true]) # sanity: two frames, one digest
      expect(outcome).to be_recovered
      expect(outcome.response.content).to eq(canned.content)
    end
  end

  # A legacy interleaved WAL (written before frames were serialized) can leave a
  # mis-slotted region -- exactly the "bytes trail a terminator record" shape the
  # strict Reader refuses. Salvage must still reach a CLEAN frame written after
  # it and report the skip, never lose a paid-for response to corruption
  # elsewhere in the file.
  describe "a corrupt region before a clean newer frame" do
    it "recovers the clean frame tolerantly and reports the skipped region, never raising" do
      request = anthropic_request
      wal = Lain::Provider::ResponseWal
      clean_sse = AnthropicSSE.body(canned)
      corrupt = "#{wal.header_record("corrupt-old", "anthropic-sse")}body#{wal.terminator_record(4, true)}TRAILING"
      header = wal.header_record(request.digest, "anthropic-sse")
      clean = header + clean_sse + wal.terminator_record(clean_sse.bytesize, true)
      File.binwrite(@wal_path, corrupt + clean)

      # The strict reader refuses this file outright -- that is why salvage reads
      # it tolerantly.
      expect { wal.new(@wal_path).frames.to_a }.to raise_error(wal::CorruptFrame)

      outcome = described_class.new(entries: [request_sent(request.digest)],
                                    frames: wal.new(@wal_path).salvageable_frames, timeline:).call

      expect(outcome).to be_recovered
      expect(outcome.response.content).to eq(canned.content)
      expect(outcome.notice).to include("recovered", "corrupt region")
    end
  end

  describe "an incomplete frame" do
    it "is surfaced as a reviewable artifact, never committed, and leaves the Timeline head unchanged" do
      wal = Lain::Provider::ResponseWal.new(@wal_path)
      raw = "event: message_start\ndata: {\"type\":\"message_start\""
      wal.open_frame(request_digest: "req-incomplete", wire: "anthropic-sse").append(raw)
      # crash: no #close -- the terminator never lands, so the Reader resyncs it as torn

      outcome = described_class.new(entries: [request_sent("req-incomplete")], frames:, timeline:).call

      expect(outcome).not_to be_recovered
      expect(outcome.request_digest).to eq("req-incomplete")
      expect(outcome.bytes).to eq(raw.bytesize)
      expect(outcome.notice).to include("req-incomplete", raw.bytesize.to_s)
    end

    it "answers a zero-byte artifact when nothing for the digest ever reached the WAL" do
      outcome = described_class.new(entries: [request_sent("req-nothing-on-disk")], frames: [], timeline:).call

      expect(outcome).not_to be_recovered
      expect(outcome.bytes).to eq(0)
    end
  end

  describe "nothing to salvage" do
    it "is a clean no-op when the last request_sent already has a turn_usage" do
      entries = [request_sent("d1"), turn_usage("d1")]

      outcome = described_class.new(entries:, frames: [], timeline:).call

      expect(outcome).to be(described_class::Nothing)
      expect(outcome.notice).to be_nil
    end

    # The agent writes a committed turn's record ahead of its usage, so a kill
    # between the two leaves the turn itself as the proof the response landed.
    it "is a clean no-op when the last request_sent is followed by an assistant turn record" do
      entries = [request_sent("d1"), turn_record("user"), turn_record("assistant")]

      outcome = described_class.new(entries:, frames: [], timeline:).call

      expect(outcome).to be(described_class::Nothing)
    end

    it "still treats a request as unanswered when only a user turn follows it" do
      entries = [request_sent("d1"), turn_record("user")]

      outcome = described_class.new(entries:, frames: [], timeline:).call

      expect(outcome).not_to be(described_class::Nothing)
    end

    it "is a clean no-op when there is no request_sent at all" do
      outcome = described_class.new(entries: [], frames: [], timeline:).call

      expect(outcome).to be(described_class::Nothing)
    end

    it "looks only at the LAST request_sent -- an earlier answered one never blocks a later unanswered one" do
      entries = [request_sent("d0"), turn_usage("d0"), request_sent("d1")]

      outcome = described_class.new(entries:, frames: [], timeline:).call

      expect(outcome).not_to be(described_class::Nothing)
      expect(outcome.request_digest).to eq("d1")
    end
  end

  # Fix round (panel: Aaron): an unanswered request_sent followed by a
  # `rewound` record is a response the user EXPLICITLY abandoned -- salvage
  # committing it onto the post-rewind head would silently reverse the
  # rewind, with a session_closed anchor on top.
  describe "a rewound record supersedes the candidate" do
    def rewound = JSON.parse(JSON.generate(Lain::SessionRecord.rewound(from: "blake3:#{"a" * 64}", to: nil)))

    it "does not resurrect a rewound-away response: a rewound AFTER the request_sent yields Nothing" do
      spool(canned)

      outcome = described_class.new(entries: [request_sent(anthropic_request.digest), rewound],
                                    frames:, timeline:).call

      expect(outcome).to be(described_class::Nothing)
    end

    it "still salvages a request_sent issued AFTER the rewind -- only a LATER rewound invalidates" do
      digest = spool(canned)

      outcome = described_class.new(entries: [rewound, request_sent(digest)], frames:, timeline:).call

      expect(outcome).to be_recovered
      expect(outcome.request_digest).to eq(digest)
    end
  end

  # A recovered Response must equal what the live call would have produced, so
  # the anthropic path decodes through the shared wire decoder the live
  # provider uses rather than a copy of it.
  describe "agreement with the shared Anthropic-wire decoder" do
    let(:assembled) do
      Lain::Provider::Anthropic::StreamAssembler::Assembled.new(
        id: "msg_1", model: "claude-opus-4-8", stop_reason: "end_turn",
        content: [{ "type" => "thinking", "thinking" => "...", "signature" => "sig" },
                  { "type" => "tool_use", "id" => "tu_1", "name" => "t", "input" => { "path" => "a.rb" } }],
        usage: { "input_tokens" => 10, "output_tokens" => 4, "cache_read_input_tokens" => 8 }
      )
    end

    let(:assembled_response) do
      Lain::Response.new(id: assembled.id, model: assembled.model, content: assembled.content,
                         stop_reason: assembled.stop_reason, usage: Lain::Usage.from_anthropic_wire(assembled.usage))
    end

    it "builds the identical Response from the identical stream" do
      digest = spool(assembled_response)
      shared = Lain::Provider::Anthropic.new(transport: Object.new, api_key: "k").send(:build_response, assembled)

      recovered = Lain::Provider::Reassembly.call(frames.to_a.last, ceiling: 64)

      expect(described_class.new(entries: [request_sent(digest)], frames:, timeline:).call.response).to eq(recovered)
      expect(recovered.content).to eq(shared.content)
      expect(recovered.usage).to eq(shared.usage)
      expect(recovered.stop_reason).to eq(shared.stop_reason)
    end
  end

  describe "a frame an ollama provider wrote" do
    def ollama_request
      Lain::Request.new(model: "qwen3:4b", max_tokens: 64, messages: [{ role: "user", content: "hi" }])
    end

    def ollama_line(message, done:, **tail)
      "#{JSON.generate({ "model" => "qwen3:4b", "message" => { "role" => "assistant" }.merge(message),
                         "done" => done }.merge(tail))}\n"
    end

    def spool_ollama(ndjson)
      stub_request(:post, %r{/api/chat})
        .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" }, body: ndjson)
      Lain::Provider::Ollama.new(config: zero_retry_config, spool: Lain::Provider::ResponseWal.new(@wal_path))
                            .complete(ollama_request)
      ollama_request.digest
    end

    def sent_with_ceiling(digest) = request_sent(digest).merge("payload" => { "max_tokens" => 64 })

    it "recovers the thinking and the text whole, and says so" do
      digest = spool_ollama(ollama_line({ "content" => "hello ", "thinking" => "hm" }, done: false) +
                            ollama_line({ "content" => "world" }, done: true, "done_reason" => "stop",
                                                                  "prompt_eval_count" => 5, "eval_count" => 2))

      outcome = described_class.new(entries: [sent_with_ceiling(digest)], frames:, timeline:).call

      expect(outcome).to be_recovered
      expect(outcome.turn.role).to eq("assistant")
      expect(outcome.turn.content).to eq([{ "type" => "thinking", "thinking" => "hm" }, *text("hello world")])
      expect(outcome.notice).to include("recovered")
    end

    it "reads the request's own ceiling, so a reply the window cut is not read as a spent cap" do
      digest = spool_ollama(ollama_line({ "content" => "par" }, done: true, "done_reason" => "length",
                                                                "eval_count" => 10))

      outcome = described_class.new(entries: [sent_with_ceiling(digest)], frames:, timeline:).call

      expect(outcome.response.stop_reason).to eq(:context_full)
    end

    it "commits nothing when the frame reassembles to no content, and names the frame in its notice" do
      digest = spool_ollama(ollama_line({ "content" => "" }, done: true, "done_reason" => "stop"))

      outcome = described_class.new(entries: [sent_with_ceiling(digest)], frames:, timeline:).call

      expect(outcome).to be_a(described_class::Unreadable)
      expect(outcome).not_to be_recovered
      expect(outcome.request_digest).to eq(digest)
      expect(outcome.notice).to include("held no answer", digest, "ollama-ndjson")
      expect(outcome.notice).not_to include("recovered turn")
    end
  end

  # A header without a wire key is corrupt: guessing the wire from the body
  # would read an anthropic frame as ollama's or the reverse.
  describe "a frame whose header names no wire" do
    it "is a skipped corrupt region, and the notice names the missing key" do
      body = %({"model":"m","message":{"role":"assistant","content":"hello"},"done":true}\n)
      header = "\x1e{\"request_digest\":\"blake3:old\",\"at\":\"2026-10-01T00:00:00Z\"}\n"
      File.binwrite(@wal_path, "#{header}#{body}#{Lain::Provider::ResponseWal.terminator_record(body.bytesize, true)}")

      outcome = described_class.new(entries: [request_sent("blake3:old")],
                                    frames: Lain::Provider::ResponseWal.new(@wal_path).salvageable_frames,
                                    timeline:).call

      expect(outcome).not_to be_recovered
      expect(outcome.notice).to include("corrupt region", "wire")
    end
  end

  # A resume must never die on the one frame it was asked to read back, so a
  # frame that cannot be decoded is reported, not raised.
  describe "a complete frame that cannot be reassembled" do
    def complete(bytes, wire)
      Lain::Provider::ResponseWal::Entry.new(request_digest: "d1", bytes: bytes.b, complete: true, wire:)
    end

    def salvaged(frame) = described_class.new(entries: [request_sent("d1")], frames: [frame], timeline:).call

    it "is Unreadable when its wire has no decoder" do
      outcome = salvaged(complete("hello", "carrier-pigeon"))

      expect(outcome).to be_a(described_class::Unreadable)
      expect(outcome.notice).to include("held no answer", "d1", "carrier-pigeon")
    end

    it "is Unreadable when no wire was recorded, and says so" do
      expect(salvaged(complete("raw", nil)).notice).to include("held no answer", "no wire was recorded")
    end

    it "is Unreadable when its bytes do not parse under the wire it names" do
      ["not json at all\n", "data: {broken\n\n"].zip(%w[ollama-ndjson anthropic-sse]).each do |bytes, wire|
        outcome = salvaged(complete(bytes, wire))

        expect(outcome).to be_a(described_class::Unreadable)
        expect(outcome.notice).to include("held no answer", wire, "could not be reassembled", "JSON::ParserError")
      end
    end

    it "is Unreadable when its bytes are not valid UTF-8, naming the error" do
      outcome = salvaged(complete(%({"message":{"content":"\xFF"},"done":true}\n), "ollama-ndjson"))

      expect(outcome).to be_a(described_class::Unreadable)
      expect(outcome.notice).to include("held no answer", "Encoding::CompatibilityError")
    end

    it "is Unreadable when its JSON is not the shape the wire carries, naming the error" do
      %w[ollama-ndjson ollama-json anthropic-json].each do |wire|
        outcome = salvaged(complete("[1]\n", wire))

        expect(outcome).to be_a(described_class::Unreadable)
        expect(outcome.notice).to include("held no answer", wire, "TypeError")
      end
    end
  end
end
