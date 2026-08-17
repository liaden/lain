# frozen_string_literal: true

require "fileutils"
require "prism"

# The recording posture for ollama, PROVEN rather than asserted in prose.
#
# The plan listed five blockers to recording an ollama cassette. Two of them
# were real, two were already solved by machinery nobody had measured, and this
# file is where the difference is written down -- because "we added a thing" and
# "the thing was already there" look identical in a green suite, and the next
# reader has to be able to tell which one they are looking at.
#
#   REAL, fixed here:
#     * spec/support/tags.rb demanded ANTHROPIC_API_KEY for ANY recording.
#     * spec/support/ollama_probe.rb's global `GET /api/ps` stub beat a cassette
#       that had one -- VCR registers itself as a WebMock GLOBAL stub, and
#       WebMock consults locally registered stubs first, so the probe won every
#       time. Measured, not read off the docs.
#
#     * Recording was scoped to the provider `LAIN_RECORD` names. It was not:
#       `record:` is a GLOBAL cassette option, so naming a provider chose only
#       which CREDENTIAL to demand, and `LAIN_RECORD=ollama` armed :new_episodes
#       on the committed Anthropic cassette with no key in the process. Measured
#       with a socket tripwire: a real connection to api.anthropic.com:443.
#
#   ALREADY TRUE, pinned here so a future change cannot quietly take it away:
#     * Ordering of repeated identical requests. VCR deletes an interaction when
#       it plays it, unconditionally, so a multi-turn cassette of identical
#       `POST /api/chat` URIs replays in recorded order with no help. No
#       ollama-specific matcher was needed, and adding one would have bought
#       nothing. `allow_playback_repeats: false` is NOT what buys that -- it buys
#       EXHAUSTION, and flipping it reds only the exhaustion example below.
#     * A recording cassette needs no network PERMISSION. Inside a recording
#       cassette `VCR.real_http_connections_allowed?` is already true, so
#       `NetworkAccess.permit_loopback` contributes nothing to a recording and
#       narrows nothing (it is inert whenever a cassette is inserted -- see
#       spec/support/network_access.rb). The recording path takes no permission
#       at all; what it needed was for nothing to CALL `NetworkAccess.permit`,
#       whose `VCR.turned_off` silently un-inserts the cassette.
#
# That last measurement is the hazard, not the reassurance: a recording cassette
# is UNBOUNDED egress, for every host, with no credential in front of it. Every
# fix below follows from taking it that way round.
#
# Cassettes here are written into a TEMP library, never spec/fixtures: a
# cassette is committed forever, and T13 owns the ones that are.
#
# Every example below pins `record: :none` rather than inheriting the suite
# default, because what it tests is REPLAY posture and the suite default is the
# one thing `LAIN_RECORD` moves. Left to inherit, a `LAIN_RECORD=ollama`
# recording pass would flip these to :new_episodes and send each of them at a
# real localhost:11434 -- which is both a false failure and, against a host that
# drops rather than refuses, a 30-second wait on the watchdog.
module T3OllamaPosture
  module_function

  # Ollama's own default; the cassette URIs have to agree with whatever the
  # provider is pointed at, and the provider is pointed at this.
  API_BASE = "http://localhost:11434"

  # A cassette VCR will deserialize. `recorded_at` is not optional -- VCR
  # fetches it rather than defaulting it, and its absence is a bare KeyError
  # from deep inside `HTTPInteraction.from_hash`.
  def interaction(method, path, body)
    { "request" => { "method" => method.to_s, "uri" => "#{API_BASE}#{path}",
                     "body" => { "encoding" => "UTF-8", "string" => "" }, "headers" => {} },
      "response" => { "status" => { "code" => 200, "message" => "OK" },
                      "headers" => { "Content-Type" => ["application/json"] },
                      "body" => { "encoding" => "UTF-8", "string" => body } },
      "recorded_at" => "Mon, 17 Aug 2026 00:00:00 GMT" }
  end

  def chat_body(text)
    JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                  "message" => { "role" => "assistant", "content" => text },
                  "prompt_eval_count" => 11, "eval_count" => 7)
  end

  # "t3_ollama_chat" holds two interactions on ONE URI: the shape the plan
  # believed replayed the first response forever.
  def cassettes
    {
      "t3_ollama_chat" => [interaction(:post, "/api/chat", chat_body("first")),
                           interaction(:post, "/api/chat", chat_body("second"))],
      "t3_ollama_process_status" => [
        interaction(:get, "/api/ps",
                    JSON.generate("models" => [{ "model" => "qwen3:4b", "context_length" => 8192 }]))
      ]
    }
  end

  # `NetworkAccess.permit(...)` as a CALL, ignoring the same words in a comment.
  # `permit_loopback` is a different method and deliberately does not count.
  def calls_blunt_permit?(source)
    blunt_permit?(Prism.parse(source).value)
  end

  def blunt_permit?(node)
    return false unless node.is_a?(Prism::Node)

    blunt_permit_call?(node) || node.compact_child_nodes.any? { |child| blunt_permit?(child) }
  end

  def blunt_permit_call?(node)
    node.is_a?(Prism::CallNode) && node.name == :permit && network_access?(node.receiver)
  end

  # Both spellings. `::NetworkAccess` parses as a ConstantPathNode with a nil
  # parent, NOT a ConstantReadNode -- and root-qualifying is house style at a
  # shadowing site (CLAUDE.md teaches `::Lain::Sensitivity`), so a contributor
  # following it would otherwise walk straight past this guard.
  def network_access?(receiver)
    case receiver
    when Prism::ConstantReadNode, Prism::ConstantPathNode then receiver.name == :NetworkAccess
    else false
    end
  end

  def write_cassettes(dir)
    cassettes.each do |name, interactions|
      File.write(File.join(dir, "#{name}.yml"),
                 { "http_interactions" => interactions, "recorded_with" => "VCR 6.4.0" }.to_yaml)
    end
  end

  # An `around`, because VCR 6.4.0 inserts a cassette from a
  # `config.before(:each, :vcr)` (`vcr/test_frameworks/rspec.rb:36`) -- not the
  # `around` one might expect. Config-level before hooks run ahead of a group's
  # own, so a `before` here would swap the library only after the cassette had
  # already been resolved against the real one. An `around` at any level wraps
  # every before hook, which is what makes this the hook that works AND the one
  # that leaves no state behind between examples.
  def with_temp_library
    original = VCR.configuration.cassette_library_dir
    Dir.mktmpdir("t3-ollama-posture") do |dir|
      VCR.configuration.cassette_library_dir = dir
      write_cassettes(dir)
      begin
        yield
      ensure
        VCR.configuration.cassette_library_dir = original
      end
    end
  end
end

RSpec.describe "the VCR harness's ollama posture" do
  around { |example| T3OllamaPosture.with_temp_library { example.run } }

  def prompt
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64, stream: false,
                      messages: [{ role: "user", content: "hello" }])
  end

  def provider
    Lain::Provider::Ollama.new(api_base: T3OllamaPosture::API_BASE)
  end

  describe "replaying a recorded ollama chat", :vcr do
    it "returns the recorded response with no server running",
       vcr: { cassette_name: "t3_ollama_chat", record: :none } do
      response = provider.complete(prompt)

      expect(response.blocks_of_type("text").map { |block| block["text"] }).to eq(["first"])
      expect(response.model).to eq("qwen3:4b")
      expect(response.usage.input_tokens).to eq(11)
    end

    # The other half of "no network was attempted": the cassette is the whole
    # boundary, so a request it does not hold cannot leave the machine.
    it "refuses a request the cassette does not hold, rather than reaching out",
       vcr: { cassette_name: "t3_ollama_chat", record: :none } do
      expect(VCR.current_cassette.recording?).to be(false)
      expect { Net::HTTP.get(URI("#{T3OllamaPosture::API_BASE}/api/version")) }
        .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
    end

    # Blocker #3, measured rather than assumed. Both turns are `POST /api/chat`
    # under `match_requests_on: %i[method uri]`, and they still come back in
    # recorded order because VCR deletes an interaction when it plays it --
    # unconditionally, with no option in front of it. `allow_playback_repeats`
    # does NOT protect this example; flipping it leaves this one green and reds
    # only the exhaustion example below.
    it "replays two identical POST /api/chat interactions in recorded order",
       vcr: { cassette_name: "t3_ollama_chat", record: :none } do
      first = provider.complete(prompt)
      second = provider.complete(prompt)

      expect(first.blocks_of_type("text").first["text"]).to eq("first")
      expect(second.blocks_of_type("text").first["text"]).to eq("second")
    end

    # VCR's own error, unwrapped -- `wrapping_errors` maps Faraday's failures,
    # and this one is raised beneath that layer. Its message says "it has
    # already been played back", which is the exhaustion being asserted.
    it "raises once the recorded interactions are exhausted, rather than repeating the last",
       vcr: { cassette_name: "t3_ollama_chat", record: :none } do
      2.times { provider.complete(prompt) }

      expect { provider.complete(prompt) }
        .to raise_error(VCR::Errors::UnhandledHTTPRequestError, /already been played back/)
    end
  end

  # Blocker #2. spec/support/ollama_probe.rb registers a global `GET /api/ps`
  # stub for EVERY example, and a locally registered WebMock stub is consulted
  # before VCR's global one -- so without the fix the cassette below is never
  # reached and the provider reports no served window.
  describe "the process-status probe stub", :vcr do
    it "yields to a cassette that records /api/ps",
       vcr: { cassette_name: "t3_ollama_process_status", record: :none } do
      expect(provider.context_window_tokens("qwen3:4b")).to eq(8192)
    end

    it "still covers an example whose cassette has no /api/ps",
       vcr: { cassette_name: "t3_ollama_chat", record: :none } do
      expect(provider.context_window_tokens("qwen3:4b")).to be_nil
    end

    # The endpoint the whole fix is about must exhaust as loudly as /api/chat
    # does. VCR DELETES an interaction when it plays it, so a predicate that
    # reads only the unplayed ones says "the cassette cannot answer" on the
    # second probe and hands the request back to the fallback stub -- turning
    # VCR's `already been played back` into a silent `nil`. That is F3's shape,
    # and `context_window_tokens` is probed once per TURN: a three-turn cassette
    # would replay three good answers and then feed compaction a quiet nil.
    it "raises on a SECOND /api/ps rather than reverting to the empty-models stub",
       vcr: { cassette_name: "t3_ollama_process_status", record: :none } do
      expect(provider.context_window_tokens("qwen3:4b")).to eq(8192)

      expect { provider.context_window_tokens("qwen3:4b") }
        .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
    end

    # Cassettes NEST, and `VCR.current_cassette` is only the innermost. A probe
    # answered by an outer cassette is still answered by a cassette, so the
    # question has to be asked of the whole stack.
    it "answers from an OUTER cassette when the inner one has no /api/ps",
       vcr: { cassette_name: "t3_ollama_process_status", record: :none } do
      VCR.use_cassette("t3_ollama_chat", record: :none) do
        expect(provider.context_window_tokens("qwen3:4b")).to eq(8192)
      end
    end
  end

  # Deliberately OUTSIDE the `:vcr` group above. A tag on a `describe` is
  # inherited by every example in it, and VCR names a cassette after the example
  # when the metadata does not -- so an example written in there to mean "no
  # cassette" silently gets one, and under a recording run gets a RECORDING one.
  # That is not hypothetical: it is how this file first reached a live ollama.
  describe "the process-status probe stub, with no cassette in play" do
    it "answers the empty-models default, as it did before cassettes existed" do
      expect(provider.context_window_tokens("qwen3:4b")).to be_nil
    end
  end
end

# The question the probe stub asks, against REAL cassettes rather than doubles --
# the doubled version of this group passed while every case the reviewer measured
# was broken, because a double cannot delete an interaction when it is played and
# cannot have a parent.
RSpec.describe VcrCassetteStack do
  around { |example| T3OllamaPosture.with_temp_library { example.run } }

  def get(path) = Net::HTTP.get(URI("#{T3OllamaPosture::API_BASE}#{path}"))

  it "says no when no cassette is inserted" do
    expect(described_class.serves?("/api/ps")).to be(false)
  end

  it "says no when the inserted cassette holds no such path" do
    VCR.use_cassette("t3_ollama_chat", record: :none) do
      expect(described_class.serves?("/api/ps")).to be(false)
    end
  end

  # A prefix must be a whole path segment. Latent while /api/ps is the only
  # caller, and a trap for the second one.
  it "does not let a parent path claim a longer sibling" do
    VCR.use_cassette("t3_ollama_chat", record: :none) do
      expect(described_class.serves?("/api/ch")).to be(false)
      expect(described_class.serves?("/api/chat")).to be(true)
    end
  end

  it "says yes when the inserted cassette holds one to replay" do
    VCR.use_cassette("t3_ollama_process_status", record: :none) do
      expect(described_class.serves?("/api/ps")).to be(true)
    end
  end

  # The S4 case. VCR deletes an interaction when it plays it, so "still holds
  # one" is false immediately after the only /api/ps has been served -- and the
  # fallback stub coming back at that moment is what turns a loud exhaustion
  # into a silent nil. Ownership has to survive playback.
  it "keeps saying yes after the recorded interaction has been played" do
    VCR.use_cassette("t3_ollama_process_status", record: :none) do
      get("/api/ps")

      expect(described_class.serves?("/api/ps")).to be(true)
    end
  end

  # The S6 case: `VCR.current_cassette` is the INNERMOST only.
  it "reads the whole stack, so an outer cassette's path still counts" do
    VCR.use_cassette("t3_ollama_process_status", record: :none) do
      VCR.use_cassette("t3_ollama_chat", record: :none) do
        expect(described_class.serves?("/api/ps")).to be(true)
      end
    end
  end

  # The one that lets a request out, and it must: a recording pass exists to
  # capture the real `/api/ps`, and a stub in front of it would record the stub.
  # This is also why an example meaning "no cassette" must not sit under a `:vcr`
  # describe -- under LAIN_RECORD its inherited cassette is a recording one.
  it "says yes to a RECORDING cassette, which is what lets the real probe be captured" do
    allow(VCR).to receive(:cassettes).and_return([instance_double(VCR::Cassette, recording?: true)])

    expect(described_class.serves?("/api/ps")).to be(true)
  end
end

# Blocker #4 and blocker #3's real subject: the permission an example takes, which
# is a different answer once a CASSETTE is in play. Three tags reach for
# `NetworkAccess.permit` and all three are registered from files that sort before
# vcr_configuration.rb, so all three had the same silent failure.
RSpec.describe ExampleNetwork do
  around { |example| T3OllamaPosture.with_temp_library { example.run } }

  # Reproduces the hook order exactly: the permission is taken FIRST (an
  # `around`), and VCR inserts the cassette afterwards (a `before`). Getting
  # that order wrong is what makes this look harmless in a console.
  def cassette_reaching(metadata)
    described_class.permit(metadata) do
      VCR.insert_cassette("t3_ollama_chat", record: :none)
      begin
        VCR.current_cassette&.name
      ensure
        VCR.eject_cassette
      end
    end
  end

  it "leaves a cassette-backed example its cassette" do
    expect(cassette_reaching({ vcr: true })).to eq("t3_ollama_chat")
  end

  # The hazard, pinned rather than described: nothing raises, the example passes,
  # and the recording it was supposed to make does not exist.
  it "SILENTLY drops the cassette of an example that takes the blunt permission" do
    expect(cassette_reaching({})).to be_nil
  end

  # The other half, and the one a reader will meet in a console: taken from
  # INSIDE an inserted cassette the same call raises, naming the cassette. Both
  # halves are the same method; only the order differs.
  it "raises loudly, naming the cassette, when taken from inside one" do
    VCR.use_cassette("t3_ollama_chat", record: :none) do
      expect { described_class.permit({}) { nil } }
        .to raise_error(VCR::Errors::CassetteInUseError, /t3_ollama_chat/)
    end
  end

  # S5: `vcr: false` is how someone says "no cassette here", and both RSpec's
  # filter and VCR's own `when_tagged_with_vcr` test truthiness, not presence.
  # Reading presence gave such an example no permission and no reachability
  # probe, so it died on a closed network instead of skipping.
  it "treats `vcr: false` as no cassette, the way RSpec and VCR both do" do
    expect(described_class.cassette_backed?({ vcr: false })).to be(false)
  end

  it "treats a cassette-name string as a cassette" do
    expect(described_class.cassette_backed?({ vcr: "some_cassette" })).to be(true)
  end

  # Blocker #3 made unviolatable instead of written down. The bug was one object
  # missing and three call sites free to skip it; this is the same shape as
  # spec/output_discipline_spec.rb, and it is what stops the next tag from
  # quietly becoming a fourth.
  #
  # Parsed, not grepped: four of the six textual occurrences under spec/support
  # are prose explaining the trap, and a guard that counted those would have to
  # be loosened the first time somebody documented it properly.
  # Root-qualifying is house style at a shadowing site, so the guard has to see
  # `::NetworkAccess.permit` as the same call. Asserted on source text rather
  # than on the tree, because the tree is (correctly) clean of both spellings.
  it "recognises a root-qualified caller, which house style would produce" do
    expect(T3OllamaPosture.calls_blunt_permit?("::NetworkAccess.permit { nil }")).to be(true)
  end

  it "recognises the plain spelling" do
    expect(T3OllamaPosture.calls_blunt_permit?("NetworkAccess.permit { nil }")).to be(true)
  end

  it "does not count permit_loopback, which is the narrow one" do
    expect(T3OllamaPosture.calls_blunt_permit?("NetworkAccess.permit_loopback(1) { nil }")).to be(false)
  end

  it "does not count the words appearing in a comment" do
    expect(T3OllamaPosture.calls_blunt_permit?("# reach the network through NetworkAccess.permit\n")).to be(false)
  end

  it "is the only caller of NetworkAccess.permit under spec/support" do
    callers = Dir[File.expand_path("../support/**/*.rb", __dir__)].select do |file|
      T3OllamaPosture.calls_blunt_permit?(File.read(file))
    end

    expect(callers.map { |file| File.basename(file) }).to contain_exactly("tags.rb")
  end
end

# Blocker #1: what `LAIN_RECORD` asks for, and what that therefore requires.
# Every method takes its input as an argument so this reads the harness without
# mutating the process's ENV -- the suite runs in parallel workers and a
# recording flag is exactly the sort of global a spec must not leave behind.
RSpec.describe VcrRecording do
  describe ".provider" do
    it "reads =1 as anthropic, so every invocation already in a shell history means what it did" do
      expect(described_class.provider("1")).to eq(:anthropic)
    end

    it "names ollama when ollama is what is being recorded" do
      expect(described_class.provider("ollama")).to eq(:ollama)
    end

    it "is nil when no recording was asked for" do
      expect(described_class.provider(nil)).to be_nil
    end

    # A typo that quietly replayed would end a recording pass with a green suite
    # and no new cassette, which is the failure this bench cannot afford to
    # make silent.
    it "refuses an unknown provider by name rather than falling back to replay" do
      expect { described_class.provider("olama") }.to raise_error(ArgumentError, /olama/)
    end
  end

  # BLOCKER B1. Naming a provider must decide WHICH CASSETTES RECORD, not merely
  # which credential to demand. `record:` is a global cassette option, so the
  # first version of this card left `LAIN_RECORD=ollama` arming :new_episodes on
  # the committed, secret-filtered Anthropic cassette with no key in the process
  # -- measured opening a real socket to api.anthropic.com:443. A cassette states
  # its owner; a mode is only ever earned by the owner LAIN_RECORD names.
  describe ".record_mode" do
    it "records the cassettes of the provider that was named" do
      expect(described_class.record_mode(owner: :ollama, requested: "ollama")).to eq(:new_episodes)
    end

    it "leaves ANOTHER provider's cassettes at :none during that same pass" do
      expect(described_class.record_mode(owner: :anthropic, requested: "ollama")).to eq(:none)
    end

    it "still records anthropic's own cassettes under the historical =1" do
      expect(described_class.record_mode(owner: :anthropic, requested: "1")).to eq(:new_episodes)
    end

    it "leaves ollama's cassettes at :none under =1, which asked for anthropic" do
      expect(described_class.record_mode(owner: :ollama, requested: "1")).to eq(:none)
    end

    it "replays only what is committed when nothing was asked for" do
      expect(described_class.record_mode(owner: :anthropic, requested: nil)).to eq(:none)
    end

    # The default owner is what keeps `LAIN_RECORD=1` meaning exactly what it
    # meant: every cassette committed before owners existed is Anthropic's.
    it "treats a cassette that names no owner as anthropic's" do
      expect(described_class.record_mode(requested: "1")).to eq(:new_episodes)
      expect(described_class.record_mode(requested: "ollama")).to eq(:none)
    end

    # The wiring, not just the function: the suite's global default must be the
    # mode an UNOWNED cassette earns, never "recording was asked for at all".
    it "is what the suite's global cassette default is built from" do
      expect(VCR.configuration.default_cassette_options[:record])
        .to eq(described_class.record_mode(owner: described_class::DEFAULT_OWNER))
    end
  end

  # How a cassette declares its owner: `records: :ollama` beside the `:vcr` tag.
  # T13 and T14 need this to record at all, and every other `:vcr` example in the
  # tree needs to stay untouched while they do.
  describe ".cassette_options" do
    it "hands an ollama-owned example the mode an ollama pass earns" do
      expect(described_class.cassette_options({ vcr: {}, records: :ollama }, "ollama"))
        .to include(record: :new_episodes)
    end

    it "holds an anthropic-owned example at :none through that pass" do
      expect(described_class.cassette_options({ vcr: {}, records: :anthropic }, "ollama"))
        .to include(record: :none)
    end

    it "keeps a cassette name given as a bare string" do
      expect(described_class.cassette_options({ vcr: "named", records: :ollama }, nil))
        .to include(cassette_name: "named")
    end

    it "never overrides a record mode the example pinned itself" do
      expect(described_class.cassette_options({ vcr: { record: :none }, records: :ollama }, "ollama"))
        .to include(record: :none)
    end

    # The last way to open unscoped egress with no flag set at all. A pinned
    # `:none` is harmless and stays legal; a pinned RECORDING mode is refused
    # unless this pass named that cassette's owner.
    it "refuses a pinned recording mode when no flag was set" do
      expect { described_class.cassette_options({ vcr: { record: :all }, records: :ollama }, nil) }
        .to raise_error(ArgumentError, /records nil/)
    end

    it "refuses a pinned recording mode belonging to a provider this pass did not name" do
      expect { described_class.cassette_options({ vcr: { record: :new_episodes }, records: :anthropic }, "ollama") }
        .to raise_error(ArgumentError, /:anthropic/)
    end

    # The shape that declares no owner at all, which is why the derived-metadata
    # hook filters on `:vcr` rather than on `records:` -- filtering on the owner
    # key would let exactly this past.
    it "refuses a pinned recording mode from an example that declares no owner" do
      expect { described_class.cassette_options({ vcr: { record: :all } }, nil) }
        .to raise_error(ArgumentError, /:anthropic/)
    end

    it "counts :once as recording, because it writes whenever the file is absent" do
      expect { described_class.cassette_options({ vcr: { record: :once } }, nil) }
        .to raise_error(ArgumentError, /:once/)
    end

    it "allows a pinned recording mode the pass DID name" do
      expect(described_class.cassette_options({ vcr: { record: :all }, records: :ollama }, "ollama"))
        .to include(record: :all)
    end

    it "leaves a pinned :none alone, which is how a replay example keeps its footing" do
      expect(described_class.cassette_options({ vcr: { record: :none } }, "1")).to include(record: :none)
    end
  end

  describe ".missing_credential" do
    it "asks for nothing when recording ollama, which is local and keyless" do
      expect(described_class.missing_credential("ollama", {})).to be_nil
    end

    it "names ANTHROPIC_API_KEY when recording anthropic without one" do
      expect(described_class.missing_credential("1", {})).to eq("ANTHROPIC_API_KEY")
    end

    it "is satisfied by a key that is present" do
      expect(described_class.missing_credential("anthropic", { "ANTHROPIC_API_KEY" => "sk-test" })).to be_nil
    end

    it "asks for nothing when no recording was requested" do
      expect(described_class.missing_credential(nil, {})).to be_nil
    end
  end
end

# What is left that is genuinely ollama's, once the permission question moved to
# ExampleNetwork: whether an :ollama example probes for a server first.
RSpec.describe OllamaTagPosture do
  # A cassette-backed example either replays (no server needed) or records (a
  # dead server must fail loudly -- a skipped recording writes no cassette and
  # looks exactly like success).
  it "does not probe a server for a cassette-backed example" do
    expect(described_class.unreachable_reason({ vcr: true })).to be_nil
  end

  it "probes for one when the example means to reach a real server" do
    allow(OllamaTestServer).to receive(:unreachable_reason).and_return("no server")

    expect(described_class.unreachable_reason({ ollama: true })).to eq("no server")
  end

  # S5 again, on the arm where getting it wrong costs a confusing failure rather
  # than a silent one: `vcr: false` means no cassette, so this example DOES want
  # the reachability probe it would otherwise be denied.
  it "probes for one when the example says `vcr: false`" do
    allow(OllamaTestServer).to receive(:unreachable_reason).and_return("no server")

    expect(described_class.unreachable_reason({ vcr: false })).to eq("no server")
  end
end
