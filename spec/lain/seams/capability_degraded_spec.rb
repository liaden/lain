# frozen_string_literal: true

require "json"
require "stringio"

# The seam this file exists for: {Lain::Capability::Policy} had a record type, an
# emitter and a reader, and NOTHING in lib/, exe/ or bin/ ever constructed the
# policy -- so twelve POC journals carried zero `capability_degraded` records
# while {Lain::Context::CacheBreakpoints} required `:prompt_caching` from a
# provider that does not declare it. Every other spec touching this record
# HAND-CONSTRUCTS it (loader_spec, session_spec, telemetry_spec); those are
# reader and serialization tests and could not have seen the gap.
#
# So the assertions below refuse a hand-built record and refuse an injected
# policy: a real {Lain::CLI::Wiring} assembles a real chat over a real
# {Lain::Provider::Ollama} and a real {Lain::CLI::Chronicle}, the chat runs a
# turn, and the bytes that reach the journal are what is read back. Only the
# socket is stubbed -- the transport double below is the one seam, exactly the
# line spec/lain/cli/wiring_spec.rb already draws around {Lain::Provider::Mock}.
RSpec.describe "capability degradation on the chat path", :seam do
  # A canned NDJSON exchange, so a real Ollama provider completes a real turn
  # with no network. `stream` is what {Lain::Provider::Ollama#complete} reaches
  # for, since a Backend-built Context streams by default.
  def stream_lines
    [
      { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "settled" }, "done" => false },
      { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "" },
        "done" => true, "done_reason" => "stop", "prompt_eval_count" => 11, "eval_count" => 7 }
    ]
  end

  def canned_transport
    ndjson = "#{stream_lines.map { |line| JSON.generate(line) }.join("\n")}\n"
    Class.new do
      define_method(:stream) { |_payload, _headers = {}, &block| block.call(ndjson) }
      define_method(:sync_post) { |_payload, _headers = {}| Struct.new(:body).new(JSON.parse(ndjson.lines.last)) }
    end.new
  end

  # The REAL provider class, with the real CAPABILITIES declaration
  # (`%i[streaming thinking structured_output]` -- no `:prompt_caching`), over
  # the canned transport. Constructing the class is the whole point: a double
  # answering `supports?` would be asserting on the double.
  let(:ollama) { Lain::Provider::Ollama.new(transport: canned_transport) }

  # Fully capable: {Lain::Provider::Mock} defaults to the whole of
  # {Lain::Provider::CAPABILITIES}, so nothing a Context requires can be missing.
  let(:capable) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end

  # The real Backend, with only the constructed provider swapped -- provider
  # resolution's one line is what a spec cannot reach without a live socket;
  # the model, the slots, the Context and its `#requires` all stay the real
  # ones. wiring_spec.rb's `offline_backend_class`, same shape and same reason.
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, wired:)
        super(options)
        @wired = wired
      end

      def provider(**) = @wired
    end
  end

  let(:io) { StringIO.new }
  let(:chronicle) do
    Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "capability-seam.ndjson")
  end
  let(:status_feed) { instance_double(Lain::StatusFeed) }

  def wire_a_chat(provider)
    backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, wired: provider)
    wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:, status_feed:)
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
  end

  def run_a_turn(provider) = wire_a_chat(provider).ask("ping")

  def degraded_records
    io.string.each_line.filter_map { |line| Lain::Journal.parse(line) }
                       .select { |record| record["type"] == "capability_degraded" }
  end

  # The requirer this run actually has: derived from the pipeline, never named
  # by hand, so a pipeline change moves the expectation with it rather than
  # leaving a stale literal green.
  def required_capabilities = Lain::Context::REQUIRES

  it "records the capability a real ollama chat silently lost" do
    run_a_turn(ollama)

    expect(required_capabilities).to include(:prompt_caching)
    expect(ollama.supports?(:prompt_caching)).to be(false)
    expect(degraded_records.map { |record| record["capability"] }).to include("prompt_caching")
    expect(degraded_records.map { |record| record["provider"] }).to all(eq("Lain::Provider::Ollama"))
  end

  it "records nothing for a provider that supports everything its context requires" do
    run_a_turn(capable)

    expect(required_capabilities.all? { |capability| capable.supports?(capability) }).to be(true)
    expect(degraded_records).to be_empty
  end

  # [pin] The whole reason `:degrade` and not `:strict` is the wired constant:
  # `Strict#handle_missing` calls {Lain::Provider#require!}, which raises
  # {Lain::Provider::Unsupported} for `:prompt_caching` -- i.e. wiring the other
  # policy would kill every ollama chat at turn one.
  it "never aborts the chat over a capability it degraded" do
    response = nil

    expect { response = run_a_turn(ollama) }.not_to raise_error

    expect(response.text).to eq("settled")
    expect(response.stop_reason).to eq(:end_turn)
  end

  # Cardinality: the record is a SESSION fact, not a turn one. A per-turn
  # emission would put one line per capability per turn into the experiment
  # record -- and {Lain::Bench::Session::Loader#degraded} folds to a set either
  # way, so nothing downstream would ever complain about the flood.
  it "writes one record per missing capability, however many turns run" do
    agent = wire_a_chat(ollama)

    3.times { agent.ask("ping") }

    expect(degraded_records.size).to eq(1)
  end

  # What the record is FOR: {Lain::Bench::Session::Loader} folds these lines
  # into the {Lain::Capability::DegradedSet} that {Lain::Compare} refuses to
  # compare across. Asserted through the real loader, so "emitted" and
  # "readable as the run's degraded set" are one claim.
  it "loads back as the run's degraded set, through the real session loader" do
    run_a_turn(ollama)

    loaded = Lain::Bench::Session::Loader.new(io.string.each_line.to_a).recording

    expect(loaded.degraded).to eq(Lain::Capability::DegradedSet.new(%i[prompt_caching]))
  end
end
