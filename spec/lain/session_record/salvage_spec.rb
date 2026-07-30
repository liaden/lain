# frozen_string_literal: true

# T18: recovering a paid-for-but-uncommitted response from the response WAL
# when a session resumes open. `frames` are built through the REAL
# Provider::ResponseWal / Provider::Anthropic pair wherever fidelity to
# production bytes matters (response_wal_spec's own precedent), rather than
# hand-authored fixtures -- what proves this class works is that it reassembles
# EXACTLY what the live streaming path would have produced.
RSpec.describe Lain::SessionRecord::Salvage do
  around { |example| Dir.mktmpdir("salvage") { |dir| @wal_path = File.join(dir, "session.wal") and example.run } }

  def text(body) = [{ "type" => "text", "text" => body }]

  let(:timeline) { Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: text("hi")) }

  let(:canned) do
    Lain::Response.new(id: "msg_1", model: "claude-opus-4-8", stop_reason: :end_turn,
                       content: text("recovered!"), usage: Lain::Usage.new(input_tokens: 10, output_tokens: 4))
  end

  def request_sent(digest)
    { "type" => "request_sent", "digest" => digest, "payload" => {}, "stream" => true, "extra" => {} }
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

  describe "the retry ruling: the last COMPLETE frame per digest wins" do
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

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
      corrupt = "#{wal.header_record("corrupt-old")}body#{wal.terminator_record(4, true)}TRAILING"
      clean = wal.header_record(request.digest) + clean_sse + wal.terminator_record(clean_sse.bytesize, true)
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
      wal.open_frame(request_digest: "req-incomplete").append(raw)
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

  # T15 fix round (panel: Aaron): an unanswered request_sent followed by a
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

  # This class SHADOWS {Provider::AnthropicWire#build_response} rather than
  # including it -- `session_record.rb` loads before `provider.rb`, so the module
  # does not exist at class-body time (and `lain/agent`, which needs
  # SessionRecord, sits between them, so the order cannot simply swap). Nothing
  # else pins the two in agreement: a field added to the shared decoder would be
  # silently absent here, on the crash-recovery path, where the whole point is
  # that a recovered Response equals what the live call would have produced.
  describe "agreement with the shared Anthropic-wire decoder it shadows" do
    let(:assembled) do
      Lain::Provider::Anthropic::StreamAssembler::Assembled.new(
        id: "msg_1", model: "claude-opus-4-8", stop_reason: "end_turn",
        # Tool inputs already parsed, which is the documented difference between
        # the two bodies (the shared one also runs #normalize_tool_inputs). With
        # parsed inputs that step is identity, so any OTHER divergence shows.
        content: [{ "type" => "thinking", "thinking" => "...", "signature" => "sig" },
                  { "type" => "tool_use", "id" => "tu_1", "name" => "t", "input" => { "path" => "a.rb" } }],
        usage: { "input_tokens" => 10, "output_tokens" => 4, "cache_read_input_tokens" => 8 }
      )
    end

    it "builds the identical Response from the identical Assembled" do
      salvage = described_class.new(entries: [], frames: [], timeline:).send(:build_response, assembled)
      shared = Lain::Provider::Anthropic.new(transport: Object.new, api_key: "k")
                                        .send(:build_response, assembled)

      expect(salvage).to eq(shared)
    end
  end
end
