# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Telemetry do
  # T1 freed the Lain::Event name from telemetry (records moved to
  # Lain::Telemetry); T8 then reused Lain::Event for the event envelope. The
  # rename must not have left a telemetry record resolvable under Lain::Event --
  # the envelope owns the name now, and every record still lives only under
  # Lain::Telemetry.
  it "keeps every telemetry record under Lain::Telemetry, none under the reused Lain::Event name" do
    records = %i[ToolOutput Dropped ProviderRetry TurnUsage RequestSent
                 MemoryRoot CapabilityDegraded WriteRefused]
    records.each do |record|
      expect(Lain::Telemetry.const_defined?(record, false)).to be(true)
      expect(Lain::Event.const_defined?(record, false)).to be(false)
    end
  end

  # The five events whose hand-rolled guards moved to validate-then-freeze
  # (Ruling 2). Construction validates a throwaway Lain::Guard carrier BEFORE
  # the auto-frozen Data value exists, so the value never carries ActiveModel's
  # @errors / @context_for_validation ivars and stays Ractor-shareable.
  describe "validate-then-freeze construction (T6 convention)" do
    it "exposes a reachable ActiveModel Guard carrier per converted event" do
      expect(Lain::Telemetry::Guards::Dropped.new(count: 0)).to be_invalid
      expect(Lain::Telemetry::Guards::TurnUsage.new(digest: nil, stop_reason: :x)).to be_invalid
      expect(Lain::Telemetry::Guards::RequestSent.new(stream: "yes")).to be_invalid
      expect(Lain::Telemetry::Guards::MemoryRoot.new(turn_digest: nil)).to be_invalid
      expect(Lain::Telemetry::Guards::WriteRefused.new(pattern: nil)).to be_invalid
    end

    it "raises ArgumentError naming the attribute AND echoing the value, never ActiveModel::ValidationError" do
      expect { Lain::Telemetry::Dropped.new(count: 0) }
        .to raise_error(ArgumentError, "count must be a positive Integer, got 0")
      # %{value} echoes un-inspected: 'got yes', where the hand-rolled guard said 'got "yes"'.
      expect { Lain::Telemetry::RequestSent.new(digest: "d", payload: {}, stream: "yes", extra: {}) }
        .to raise_error(ArgumentError, "stream must be true or false, got yes")
      expect { Lain::Telemetry::RequestSent.new(digest: "d", payload: {}, stream: nil, extra: {}) }
        .to raise_error(ArgumentError, /stream must be true or false/)
    end

    it "leaves every valid converted event deeply frozen, Ractor-shareable, and @errors-free" do
      valid = [
        Lain::Telemetry::Dropped.new(count: 1),
        Lain::Telemetry::TurnUsage.new(digest: "d", model: nil, stop_reason: :end_turn, usage: {}),
        Lain::Telemetry::RequestSent.new(digest: "d", payload: {}, stream: false, extra: {}),
        Lain::Telemetry::MemoryRoot.new(turn_digest: "d", root: nil),
        Lain::Telemetry::WriteRefused.new(tool_use_id: "t", pattern: "p")
      ]

      valid.each do |event|
        expect(event).to be_deeply_frozen
        expect(event.instance_variables).not_to include(:@errors)
      end
    end
  end

  describe "#journal_type" do
    # The discriminator is pinned by recorded journals, so String#underscore
    # (the ActiveSupport form) MUST produce the exact string the hand-rolled
    # gsub did for every event -- a future name where they diverge fails here,
    # not silently in a replayed journal.
    it "derives each type via underscore, byte-identical to the old gsub" do
      require "active_support/core_ext/string/inflections"
      {
        "ToolOutput" => "tool_output", "Dropped" => "dropped",
        "ProviderRetry" => "provider_retry", "TurnUsage" => "turn_usage",
        "RequestSent" => "request_sent", "MemoryRoot" => "memory_root",
        "CapabilityDegraded" => "capability_degraded", "WriteRefused" => "write_refused"
      }.each do |name, expected|
        hand_rolled = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
        expect(name.underscore).to eq(expected).and eq(hand_rolled)
      end
    end

    it "is what a converted event actually reports" do
      expect(Lain::Telemetry::TurnUsage.new(digest: "d", model: nil, stop_reason: :end_turn, usage: {}).journal_type)
        .to eq("turn_usage")
    end
  end

  describe Lain::Telemetry::ToolOutput do
    subject(:event) { described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi") }

    it "rejects an unknown stream" do
      expect { described_class.new(tool_use_id: "t", stream: :nope, bytes: "x") }
        .to raise_error(ArgumentError)
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi")
      expect(event).to eq(twin)
      expect(event).to be_deeply_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(event).to be_ractor_shareable
    end

    describe "#to_journal" do
      it "is a JSON object of the attributes tagged with a snake_case type" do
        expect(event.to_journal).to eq(
          "type" => "tool_output", "tool_use_id" => "t1", "stream" => :stdout, "bytes" => "hi"
        )
      end

      it "round-trips through JSON to a parseable line" do
        expect(JSON.parse(JSON.generate(event.to_journal))).to include(
          "type" => "tool_output", "stream" => "stdout"
        )
      end
    end
  end

  describe Lain::Telemetry::Dropped do
    it "carries a positive count" do
      expect(described_class.new(count: 3).count).to eq(3)
    end

    it "rejects a non-positive count" do
      expect { described_class.new(count: 0) }.to raise_error(ArgumentError)
      expect { described_class.new(count: -1) }.to raise_error(ArgumentError)
    end

    it "is a frozen value object" do
      expect(described_class.new(count: 1)).to be_deeply_frozen
    end

    it "journals as a dropped marker" do
      expect(described_class.new(count: 5).to_journal).to eq("type" => "dropped", "count" => 5)
    end
  end

  describe Lain::Telemetry::TurnUsage do
    subject(:event) do
      described_class.new(digest: "blake3:abc123", model: "claude-opus-4-8",
                          stop_reason: :end_turn,
                          usage: { input_tokens: 10, output_tokens: 5 })
    end

    it "carries the turn digest, model, stop_reason, and usage" do
      expect(event.digest).to eq("blake3:abc123")
      expect(event.model).to eq("claude-opus-4-8")
      expect(event).to stop_with(:end_turn)
      expect(event.usage).to eq("input_tokens" => 10, "output_tokens" => 5)
    end

    it "normalizes usage to canonical wire form, so symbol- and string-keyed input are the same event" do
      twin = described_class.new(digest: "blake3:abc123", model: "claude-opus-4-8",
                                 stop_reason: :end_turn,
                                 usage: { "input_tokens" => 10, "output_tokens" => 5 })
      expect(event).to eq(twin)
      expect(event.hash).to eq(twin.hash)
    end

    it "is deeply frozen, usage hash included" do
      expect(event).to be_deeply_frozen
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(event).to be_ractor_shareable
    end

    it "rejects a nil stop_reason loudly" do
      expect { described_class.new(digest: "blake3:abc123", model: nil, stop_reason: nil, usage: {}) }
        .to raise_error(ArgumentError, /stop_reason/)
    end

    it "rejects a nil digest loudly -- a payment must name the turn it paid for" do
      expect { described_class.new(digest: nil, model: nil, stop_reason: :end_turn, usage: {}) }
        .to raise_error(ArgumentError, /digest must name the committed turn/)
    end

    it "tolerates a nil model, because a bare mock response carries none" do
      bare = described_class.new(digest: "blake3:abc123", model: nil,
                                 stop_reason: :end_turn, usage: {})
      expect(bare.model).to be_nil
      expect(bare).to be_ractor_shareable
    end

    it "journals as a turn_usage record that round-trips through JSON" do
      expect(event.to_journal).to eq(
        "type" => "turn_usage", "digest" => "blake3:abc123",
        "model" => "claude-opus-4-8", "stop_reason" => :end_turn,
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
      )
      expect(JSON.parse(JSON.generate(event.to_journal))).to include(
        "type" => "turn_usage", "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
      )
    end
  end

  describe Lain::Telemetry::RequestSent do
    let(:request) do
      Lain::Request.new(
        model: "claude-opus-4-8",
        system: [{ "type" => "text", "text" => "be terse" }],
        tools: [{ "name" => "echo", "input_schema" => { "type" => "object" } }],
        messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }],
        max_tokens: 128,
        stream: false,
        reasoning: { "budget_tokens" => 1024 },
        extra: { "service_tier" => "flex" }
      )
    end

    subject(:event) do
      described_class.new(digest: request.digest, payload: request.cache_payload,
                          stream: request.stream, extra: request.extra)
    end

    it "carries the request's cache identity plus the transport fields the digest excludes" do
      expect(event).to have_same_digest_as(request)
      expect(event.payload).to eq(request.cache_payload)
      expect(event.stream).to be(false)
      expect(event.extra).to eq("service_tier" => "flex")
    end

    it "normalizes payload and extra to canonical wire form, so symbol- and string-keyed input are the same event" do
      twin = described_class.new(digest: request.digest,
                                 payload: request.cache_payload.transform_keys(&:to_sym),
                                 stream: false, extra: { service_tier: "flex" })
      expect(event).to eq(twin)
      expect(event.hash).to eq(twin.hash)
    end

    it "is deeply frozen, payload and extra included" do
      expect(event).to be_deeply_frozen
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(event).to be_ractor_shareable
    end

    it "rejects a non-boolean stream loudly" do
      expect { described_class.new(digest: "d", payload: {}, stream: nil, extra: {}) }
        .to raise_error(ArgumentError, /stream/)
      expect { described_class.new(digest: "d", payload: {}, stream: "yes", extra: {}) }
        .to raise_error(ArgumentError, /stream/)
    end

    describe "#prefix_digests" do
      # nil = not computed; [] = computed, zero markers. The offline rewrite
      # projection (T4) needs that distinction on the wire, so absence is a
      # value here, not a missing Null Object.
      it "defaults to nil, meaning the chain was never computed" do
        expect(event.prefix_digests).to be_nil
      end

      it "journals a nil default as null and an explicit empty chain as [], distinguishably" do
        computed_empty = described_class.new(digest: request.digest, payload: request.cache_payload,
                                             stream: request.stream, extra: request.extra,
                                             prefix_digests: [])
        expect(JSON.generate(event.to_journal)).to include('"prefix_digests":null')
        expect(JSON.generate(computed_empty.to_journal)).to include('"prefix_digests":[]')
      end

      it "carries the digest chain the caller passed, normalized to canonical wire form" do
        chained = described_class.new(digest: request.digest, payload: request.cache_payload,
                                      stream: request.stream, extra: request.extra,
                                      prefix_digests: [[-1, "blake3:sys"], [0, "blake3:m0"]])
        expect(chained.prefix_digests).to eq([[-1, "blake3:sys"], [0, "blake3:m0"]])
        expect(chained.prefix_digests).to be_deeply_frozen
      end

      it "is Ractor-shareable with a populated chain" do
        chained = described_class.new(digest: request.digest, payload: request.cache_payload,
                                      stream: request.stream, extra: request.extra,
                                      prefix_digests: [[0, "blake3:m0"]])
        expect(chained).to be_ractor_shareable
      end

      it "journals as position/digest pairs that round-trip through JSON" do
        chained = described_class.new(digest: request.digest, payload: request.cache_payload,
                                      stream: request.stream, extra: request.extra,
                                      prefix_digests: [[-1, "blake3:sys"], [0, "blake3:m0"]])
        expect(chained.to_journal).to include("prefix_digests" => [[-1, "blake3:sys"], [0, "blake3:m0"]])
        expect(JSON.parse(JSON.generate(chained.to_journal))).to include(
          "prefix_digests" => [[-1, "blake3:sys"], [0, "blake3:m0"]]
        )
      end
    end

    # The one silent failure mode: Request grows a third digest-excluded
    # transport field (a sibling of stream/extra), the digest still matches,
    # every spec stays green, and the field vanishes from recorded sessions.
    # Pinning the union of captured fields to Request.members makes that
    # addition fail HERE instead.
    it "captures every Request member, so a new digest-excluded field cannot be dropped in silence" do
      captured = request.cache_payload.keys.map(&:to_sym) + %i[stream extra]
      expect(captured).to match_array(Lain::Request.members)
    end

    it "journals as a request_sent record that round-trips through JSON" do
      expect(event.to_journal).to include("type" => "request_sent", "digest" => request.digest,
                                          "stream" => false, "extra" => { "service_tier" => "flex" })
      expect(JSON.parse(JSON.generate(event.to_journal))).to include(
        "type" => "request_sent", "digest" => request.digest
      )
    end

    # The bench's load-bearing invariant: a journaled record must carry
    # EVERYTHING Request.new needs, because digest equality alone cannot prove
    # a lossless round trip -- the digest deliberately excludes stream/extra.
    # Tested through real NDJSON bytes (generate -> parse), not in-memory hashes.
    describe "lossless reconstruction from the journaled record" do
      # The splat is the point: cache_payload's keys are exactly Request.new's
      # content keywords, so the record rebuilds with no field-by-field mapping.
      def rebuild(record)
        payload = record.fetch("payload").transform_keys(&:to_sym)
        Lain::Request.new(stream: record.fetch("stream"), extra: record.fetch("extra"), **payload)
      end

      def round_trip(original)
        sent = described_class.new(digest: original.digest, payload: original.cache_payload,
                                   stream: original.stream, extra: original.extra)
        record = JSON.parse(JSON.generate(sent.to_journal))
        [record, rebuild(record)]
      end

      it "rebuilds a fully-populated request to the recorded digest, extra intact" do
        record, rebuilt = round_trip(request)
        expect(rebuilt.digest).to eq(record.fetch("digest"))
        expect(rebuilt).to eq(request)
      end

      it "rebuilds a minimal request -- nil system, no tools, nil reasoning -- to the recorded digest" do
        minimal = Lain::Request.new(
          model: "claude-opus-4-8",
          messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }],
          max_tokens: 64
        )
        record, rebuilt = round_trip(minimal)
        expect(rebuilt.digest).to eq(record.fetch("digest"))
        expect(rebuilt).to eq(minimal)
      end

      # Same invariant through the REAL writer: the Journal stamps "ts" onto
      # every record, and RequestSent must have no key that merge could
      # collide with -- otherwise the stamped line would rebuild differently
      # than the in-memory to_journal does.
      it "rebuilds from a line written by a real Journal, whose ts stamp joins the record without collision" do
        io = StringIO.new
        Lain::Journal.new(io:, clock: -> { "2026-07-11T00:00:00.000000Z" }).record(
          described_class.new(digest: request.digest, payload: request.cache_payload,
                              stream: request.stream, extra: request.extra)
        )

        record = JSON.parse(io.string)
        expect(record.keys).to match_array(["ts"] + event.to_journal.keys)
        expect(record.fetch("ts")).to eq("2026-07-11T00:00:00.000000Z")
        expect(rebuild(record).digest).to eq(record.fetch("digest"))
      end
    end
  end

  describe Lain::Telemetry::MemoryRoot do
    subject(:event) { described_class.new(turn_digest: "blake3:turn", root: "blake3:root") }

    it "carries the committed turn's digest and the index root in force at it" do
      expect(event.turn_digest).to eq("blake3:turn")
      expect(event.root).to eq("blake3:root")
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(turn_digest: "blake3:turn", root: "blake3:root")
      expect(event).to eq(twin)
      expect(event).to be_deeply_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable even when built from mutable Strings" do
      mutable = described_class.new(turn_digest: +"blake3:turn", root: +"blake3:root")
      expect(mutable).to be_ractor_shareable
    end

    it "rejects a nil turn_digest loudly" do
      expect { described_class.new(turn_digest: nil, root: "blake3:root") }
        .to raise_error(ArgumentError, /turn_digest/)
    end

    it "tolerates a nil root, because an empty index has no root node to name" do
      bare = described_class.new(turn_digest: "blake3:turn", root: nil)
      expect(bare.root).to be_nil
      expect(bare).to be_ractor_shareable
    end

    it "journals as a memory_root record whose nil root round-trips as JSON null" do
      expect(event.to_journal).to eq(
        "type" => "memory_root", "turn_digest" => "blake3:turn", "root" => "blake3:root"
      )

      bare = described_class.new(turn_digest: "blake3:turn", root: nil)
      line = JSON.generate(bare.to_journal)
      expect(line).to include('"root":null')
      expect(JSON.parse(line)).to include("type" => "memory_root", "root" => nil)
    end
  end

  describe Lain::Telemetry::CapabilityDegraded do
    subject(:event) do
      described_class.new(capability: :thinking, requirer: "Prune", provider: "Provider::Mock")
    end

    it "carries the capability, requirer, and provider" do
      expect(event.capability).to eq(:thinking)
      expect(event.requirer).to eq("Prune")
      expect(event.provider).to eq("Provider::Mock")
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(capability: :thinking, requirer: "Prune", provider: "Provider::Mock")
      expect(event).to eq(twin)
      expect(event).to be_deeply_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(event).to be_ractor_shareable
    end

    it "journals as a capability_degraded record that round-trips through JSON" do
      expect(event.to_journal).to eq(
        "type" => "capability_degraded", "capability" => :thinking,
        "requirer" => "Prune", "provider" => "Provider::Mock"
      )
      expect(JSON.parse(JSON.generate(event.to_journal))).to include(
        "type" => "capability_degraded", "capability" => "thinking"
      )
    end
  end

  describe Lain::Telemetry::WriteRefused do
    subject(:event) { described_class.new(tool_use_id: "tu_1", pattern: "aws access key id") }

    it "carries the tool_use_id and the NAME of the pattern that matched" do
      expect(event.tool_use_id).to eq("tu_1")
      expect(event.pattern).to eq("aws access key id")
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(tool_use_id: "tu_1", pattern: "aws access key id")
      expect(event).to eq(twin)
      expect(event).to be_deeply_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable even when built from mutable Strings" do
      mutable = described_class.new(tool_use_id: +"tu_1", pattern: +"aws access key id")
      expect(mutable).to be_ractor_shareable
    end

    it "rejects a nil pattern loudly -- a refusal record must name what matched" do
      expect { described_class.new(tool_use_id: "tu_1", pattern: nil) }
        .to raise_error(ArgumentError, /pattern/)
    end

    it "journals as a write_refused record that round-trips through JSON" do
      expect(event.to_journal).to eq(
        "type" => "write_refused", "tool_use_id" => "tu_1", "pattern" => "aws access key id"
      )
      expect(JSON.parse(JSON.generate(event.to_journal))).to eq(
        "type" => "write_refused", "tool_use_id" => "tu_1", "pattern" => "aws access key id"
      )
    end
  end

  # T1 AC2: the committed variance fixtures were written before the rename,
  # so they are the regression proof that the wire format (the `type` tags
  # Journalable#to_journal derives from the class name) did not shift under
  # Bench::Session::Loader -- the loader discriminates records by that string,
  # never by resolving a Lain::Telemetry (nee Lain::Event) class reflectively.
  describe "fixture-load regression: recorded journals still load" do
    fixture_dir = File.expand_path("../fixtures/sessions/variance", __dir__)
    fixture_paths = Dir.glob(File.join(fixture_dir, "*.ndjson"))

    it "finds the committed variance fixtures" do
      expect(fixture_paths).not_to be_empty
    end

    it "loads every fixture, and every parsed record keeps its pre-rename type tag" do
      fixture_paths.each do |path|
        lines = File.readlines(path)
        recorded_types = lines.map { |line| JSON.parse(line).fetch("type") }

        recording = Lain::Bench::Session::Loader.new(lines).recording

        expect(recording.timeline).to be_a(Lain::Timeline)
        expect(recorded_types).to include("request_sent", "turn_usage", "turn", "session")
      end
    end
  end
end
