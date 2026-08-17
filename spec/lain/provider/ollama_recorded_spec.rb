# frozen_string_literal: true

# Real ollama round trips, committed as cassettes and replayed offline through
# the REAL Faraday stack, the REAL NDJSON assembler and the REAL decode path.
# The sibling of spec/lain/provider/anthropic_recorded_spec.rb, for the arm that
# needs no key and no money -- only a GPU nobody running this suite has to own.
#
# Recorded 2026-08-17 against ollama on this box, qwen3:4b (the arm's
# DEFAULT_MODEL), with:
#
#     LAIN_RECORD=ollama bundle exec rspec spec/lain/provider/ollama_recorded_spec.rb
#
# == Re-recording, which is fiddlier than that one line suggests
#
# Delete the cassette first: `:new_episodes` records only requests the file does
# not already answer, and every request here matches one it does, so a
# re-recording over a live file is a silent no-op.
#
# Then take one GROUP at a time (`-e "a recorded streaming chat"`, and so on),
# because `config.order = :random` otherwise decides whether `/api/ps` is
# recorded before or after the chat that makes a runner resident -- and against a
# cold server `/api/ps` records `{"models":[]}`, which is exactly the empty
# default the global stub already provides. Within the chat group, record via the
# follow-up example alone: it drives both turns in order, and the sibling
# examples would append a duplicate first turn or a stray `/api/ps`.
#
# The recording pass wants `LAIN_SPEC_BUDGET` raised (the watchdog's 30s is not
# a model-load budget) and it wants nothing else running: a RECORDING cassette
# permits real connections to EVERY host, not merely this one.
#
# == Hygiene: which half is the GATE and which is the BACKSTOP
#
# `/api/show`'s `modelfile` quotes an absolute path into the recording box's blob
# store, and a cassette is committed forever. Two mechanisms, and they are not
# interchangeable:
#
#   * THE GATE is `before_record` in spec/support/vcr_configuration.rb, which
#     runs {CassetteHygiene.redact} on every body as it is WRITTEN. The path
#     cannot reach a file, so no manual step and no one-off script is involved.
#   * THE BACKSTOP is the guard group at the bottom of this file. It sweeps every
#     `ollama_*.yml` for the shapes the gate does not redact -- other boxes' home
#     directories, Windows profile paths, IP literals, MAC addresses, credential
#     HEADERS. It is a next-full-run instrument, NOT a re-recording gate: the
#     `-e` invocations above filter it out of a recording pass entirely, and
#     `config.order = :random` would otherwise decide whether it read pre- or
#     post-recording bytes.
#
# One thing was reviewed and deliberately KEPT: `recorded_at` and the `/api/ps`
# body's `expires_at` carry the recorder's UTC offset (`-04:00`), so the pair
# states a timezone. A timezone is not a schedule -- there is one timestamp per
# cassette, not a series -- and stripping it would make the cassette a worse
# record of what the server said. Judged acceptable rather than overlooked.
#
# Replay needs neither the flag nor a server: `records: :ollama` earns
# `:new_episodes` only in a pass that named ollama, and `:none` in every other,
# which is the whole of VcrRecording's owner scoping (spec/support/vcr_configuration.rb).
# Nothing here pins a `record:` of its own -- an owner plus the derived mode is
# the entire declaration, and a pinned `:none` would make these permanently
# un-recordable.
#
# == WHAT THESE CASSETTES CANNOT CATCH, said here so nobody trusts them further
#
# WebMock hands a stubbed body back as ONE CHUNK
# (spec/lain/provider/ollama/streamed_failure_spec.rb:5-9; lain.gemspec:77-80
# makes the same point about VCR storing a body as one blob). So every recording
# below replays as a single write, and a regression that SPLIT an NDJSON line
# across two TCP reads -- or spliced a retried attempt's bytes onto an abandoned
# one's -- would replay green here forever. These cassettes pin decode,
# tool-call correlation, usage and the served-window read; they do NOT cover
# F7b/F7c, which need a real severable socket and belong to T10 and T12. A
# cassette that appeared to cover them would be worse than no cassette.
#
# == The other thing to know before adding an example
#
# `Provider::Ollama#context_window_tokens` probes `GET /api/ps` once per TURN and
# is deliberately un-memoised, and a cassette that owns `/api/ps` owns it for
# good: the second probe RAISES rather than falling back to the empty-models stub
# (spec/support/ollama_probe.rb). So an N-turn cassette needs N recorded probes.
# `ollama_process_status.yml` holds exactly ONE, and the group below makes
# exactly one probe.
module T13RecordedOllama
  module_function

  # Ollama's own default, and what the committed cassettes' URIs say. The
  # provider is pointed at it explicitly rather than by default so a reader can
  # see the two agree.
  API_BASE = "http://localhost:11434"
  MODEL = Lain::Provider::Ollama::DEFAULT_MODEL

  # What `/api/ps` said the resident runner was actually being served with, at
  # recording time. `/api/show`'s trained figure is 8x larger -- the exact
  # over-estimate references/ollama/api-show-and-context.md exists to refuse --
  # and the show group asserts the gap rather than describing it.
  SERVED_CONTEXT_TOKENS = 32_768

  # Anthropic-shaped on Lain's side; Ollama::Encoding renders it as ollama's
  # `{type: "function", function: {...}}`.
  def tools
    [{ "name" => "read_file", "description" => "Read a file from the project.",
       "input_schema" => { "type" => "object",
                           "properties" => { "path" => { "type" => "string",
                                                         "description" => "Path to the file." } },
                           "required" => ["path"] } }]
  end

  # temperature 0 and a fixed seed, so a re-recording lands near the same bytes;
  # deliberately NO num_ctx, because sending one would reload the runner at a
  # different window and make the `/api/ps` recording disagree with the chat one
  # (the stale-runner trap, api-show-and-context.md).
  #
  # `think` and `structured_output` both ride Request#extra onto their own
  # top-level wire fields (Ollama::Encoding's THINK_KEY and
  # STRUCTURED_OUTPUT_KEY), and between them they are what keeps this cassette
  # readable. A streamed NDJSON body is one JSON object PER TOKEN, and qwen3:4b
  # is a Thinking finetune: asked in prose for a one-word answer it spent 248
  # tokens explaining itself, and with `think: false` it spent 276 explaining
  # itself in `content` instead. Both turns unconstrained recorded 93 KB.
  #
  # So the second turn is grammar-CONSTRAINED instead (ollama's native `format`,
  # which is what this arm's :structured_output capability actually means): 12
  # tokens, deterministic, and the capability gets a recorded round trip it did
  # not have before. The first turn stays unconstrained, because a constrained
  # one does not call a tool.
  def ask(messages, think: nil, schema: nil)
    extra = { "temperature" => 0, "seed" => 1 }
    extra["think"] = think unless think.nil?
    extra["structured_output"] = { "schema" => schema } unless schema.nil?
    Lain::Request.new(model: MODEL, max_tokens: 512, stream: true, tools:, messages:,
                      system: "You are a terse assistant. Use the read_file tool when asked to read a file.",
                      extra:)
  end

  def question
    { "role" => "user", "content" => "Read the file README.md and name the project it describes." }
  end

  def first_turn = ask([question])

  # The same conversation with the assistant's call and the tool's answer
  # appended -- an ordinary agent loop's second turn. Its body differs from the
  # first turn's and its URI does not, which is precisely the case
  # `match_requests_on: %i[method uri]` is accused of not handling: VCR deletes
  # an interaction when it plays it, so the two replay in RECORDED ORDER with no
  # body matcher (measured in spec/lain/vcr_ollama_posture_spec.rb).
  def second_turn(call)
    ask([question,
         { "role" => "assistant", "content" => [call] },
         { "role" => "user",
           "content" => [{ "type" => "tool_result", "tool_use_id" => call["id"],
                           "content" => "# Lain\n\nAn agent harness built as a study bench.\n" }] }],
        think: false,
        schema: { "type" => "object", "properties" => { "project_name" => { "type" => "string" } },
                  "required" => ["project_name"] })
  end

  def provider = Lain::Provider::Ollama.new(api_base: API_BASE)

  # `/api/show` has no consumer in lib/ yet -- capabilities discovery is a later
  # card -- so the round trip is driven at the transport, which is the boundary
  # this whole file records at. Recording it now is the point: it is the endpoint
  # that answers "may this model be handed tools", and a future card should find
  # the real answer committed rather than have to own a GPU to see one.
  #
  # The base is set EXPLICITLY here for the same reason the provider takes it:
  # under `match_requests_on: %i[method uri]` the recorded URI is what the replay
  # matches on, so leaving it to `Transport::DEFAULT_API_BASE` would make a
  # load-bearing value implicit.
  def transport
    config = Lain::Provider::HTTP::Configuration.new
    config.ollama_api_base = API_BASE
    Lain::Provider::Ollama::Transport.new(config)
  end

  def cassette_dir = File.expand_path("../../fixtures/vcr_cassettes", __dir__)

  # Every ollama cassette, not merely this card's three: T14's run-loop cassette
  # lands in the same directory and is swept by the same guard.
  def cassettes = Dir.glob(File.join(cassette_dir, "ollama_*.yml"))
end

RSpec.describe Lain::Provider::Ollama, records: :ollama do
  # Every assertion on a recorded STRING is an equality, never a pattern, and
  # that is the fourth acceptance criterion rather than fussiness: an ollama
  # server was listening on this port throughout, and a 4B model reproducing a
  # recorded sentence token-for-token is not a thing that happens. Equality
  # therefore proves the bytes came from the file rather than from the server --
  # which "passes with the network denied" could never show, since that would
  # only re-assert the suite's existing offline posture.
  #
  # The cassette name rides `vcr:` ALONE, never beside a bare `:vcr` symbol.
  # RSpec's `Metadata.build_hash_from` pops the trailing hash first and only then
  # writes `hash[:vcr] = true` for each symbol, so `:vcr, vcr: {...}` silently
  # discards the options -- and VCR falls back to naming the cassette after the
  # example, which under a recording pass writes a whole directory tree of
  # per-example files nobody asked for. It did, once, here.
  describe "a recorded streaming chat", vcr: { cassette_name: "ollama_chat_streaming" } do
    it "decodes the tool call, carrying the id the wire itself supplied" do
      response = T13RecordedOllama.provider.complete(T13RecordedOllama.first_turn)

      expect(response.model).to eq("qwen3:4b")
      expect(response.content.map { |block| block["type"] }).to eq(%w[thinking tool_use])
      expect(response).to stop_with(:tool_use)

      call = response.tool_uses.first
      # `stop_with(:tool_use)` above pins the TOOL-CALL path, not the
      # `done_reason` mapping: `decode_stop_reason` reads `tool_calls` first, so
      # mutating this turn's recorded `done_reason` to "length" leaves it green,
      # correctly. The done_reason enum is `ollama_spec.rb`'s to cover.
      expect(call["name"]).to eq("read_file")
      expect(call["input"]).to eq("path" => "README.md")
      # Native `/api/chat` carries no tool-call id in the documented shape, so
      # the provider synthesizes `ollama-tool-0`; this server sent one anyway and
      # the honoring branch is what keeps it. Seeing the synthetic id here would
      # mean the wire id had been dropped.
      expect(call["id"]).to eq("call_fvxtvjje")

      expect(response.usage.input_tokens).to eq(169)
      expect(response.usage.output_tokens).to eq(150)
    end

    # The second turn is reachable only through the first, which is the recorded
    # order: two `POST /api/chat` interactions on one URI, replayed in sequence.
    it "decodes the follow-up turn's text, model and usage" do
      provider = T13RecordedOllama.provider
      # The raw block, not the {Response::ToolUse} lens: a lens is not a
      # canonicalizable value, and a Request normalizes everything it is handed.
      call = provider.complete(T13RecordedOllama.first_turn).blocks_of_type("tool_use").first

      response = provider.complete(T13RecordedOllama.second_turn(call))

      expect(response.model).to eq("qwen3:4b")
      # Verbatim, whitespace included. Grammar-constrained decoding is what makes
      # it short enough to read; it is still the model's own bytes, not a schema
      # this spec imposed on the answer after the fact.
      expect(response.blocks_of_type("text").map { |block| block["text"] })
        .to eq([%({\n  "project_name": "Lain"\n})])
      expect(response).to stop_with(:end_turn)
      expect(response.usage.input_tokens).to eq(214)
      expect(response.usage.output_tokens).to eq(12)
    end

    # The other half of "the cassette is the boundary": a request it does not
    # hold cannot leave the machine, even though ollama is listening on exactly
    # that host and port.
    it "refuses a request the cassette does not hold, rather than reaching the live server" do
      expect(VCR.current_cassette.recording?).to be(false)

      expect { Net::HTTP.get(URI("#{T13RecordedOllama::API_BASE}/api/version")) }
        .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
    end
  end

  # `/api/ps` is the ONLY endpoint that states the served window, and the
  # empty-models stub in spec/support/ollama_probe.rb answers every other
  # example's probe -- so `nil` here would mean the cassette had lost to the
  # stub, which is T3's contract failing rather than this one's. An Integer is
  # the proof that the recorded probe won.
  describe "the served context window", vcr: { cassette_name: "ollama_process_status" } do
    it "answers the window the runner was actually loaded with" do
      expect(T13RecordedOllama.provider.context_window_tokens("qwen3:4b"))
        .to eq(T13RecordedOllama::SERVED_CONTEXT_TOKENS)
    end
  end

  # One recorded answer, two claims: the useful one (`capabilities` is the honest
  # source for whether a model may be handed tools or asked to think) and the
  # dangerous one (`model_info`'s context_length is the GGUF's TRAINED maximum
  # and must never be used as a denominator).
  #
  # Read these two as a FIXTURE, not as coverage. Nothing in lib/ consumes
  # `/api/show` yet, so they drive the transport directly and cannot red on a
  # decoder regression -- there is no decoder. What they buy is that the endpoint's
  # real answer is committed, so the card that wires capability discovery can be
  # written and tested by somebody with no GPU.
  describe "what /api/show answers", vcr: { cassette_name: "ollama_show" } do
    let(:body) { T13RecordedOllama.transport.connection.post("api/show", { model: "qwen3:4b" }).body }

    it "states the model's capabilities" do
      expect(body["capabilities"]).to include("completion", "tools", "thinking")
    end

    it "offers a context_length that is the TRAINED maximum, not the served window" do
      trained = body["model_info"]["qwen3.context_length"]

      expect(trained).to eq(262_144)
      expect(trained).to be > T13RecordedOllama::SERVED_CONTEXT_TOKENS
    end
  end
end

# Deliberately OUTSIDE every `:vcr` group above: a tag on a describe is inherited
# by every example in it, and VCR names a cassette after the example when the
# metadata does not -- so an example written in there to mean "no cassette" gets
# one anyway.
#
# A cassette is committed to this repository forever, so what is IN one is a
# permanent decision rather than a recording artifact. The rule itself lives in
# {CassetteHygiene} (spec/support/cassette_hygiene.rb) rather than here, because
# it outlives this card: the glob below sweeps every ollama cassette recorded
# after these three, and a permanent repository rule should not be reached
# through a module named for a plan card that will be archived.
RSpec.describe "the committed ollama cassettes" do
  it "exist, all three of them" do
    expect(T13RecordedOllama.cassettes.map { |path| File.basename(path) })
      .to include("ollama_chat_streaming.yml", "ollama_process_status.yml", "ollama_show.yml")
  end

  # `.to_s` rather than the Findings themselves: the failure message has to name
  # the shape and the byte offset by itself, because nobody re-reads 58 KB of
  # YAML by eye -- which is the guard's own premise.
  it "carry no local path, address, hostname or credential" do
    findings = CassetteHygiene.findings_in(T13RecordedOllama.cassettes)

    expect(findings.map(&:to_s)).to be_empty
  end

  # Small enough that a human can open one and read it. The plan's own limit is
  # "a few hundred kilobytes"; this is the tripwire for drifting toward it.
  it "stay small enough to read" do
    oversized = T13RecordedOllama.cassettes.select { |path| File.size(path) > 200_000 }

    expect(oversized).to be_empty
  end
end
