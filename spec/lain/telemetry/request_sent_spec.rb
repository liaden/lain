# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Telemetry::RequestSent do
  subject(:event) do
    described_class.new(digest: request.digest, payload: request.cache_payload,
                        stream: request.stream, extra: request.extra)
  end

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

  it "rejects a non-boolean stream loudly" do
    expect { described_class.new(digest: "d", payload: {}, stream: nil, extra: {}) }
      .to raise_error(ArgumentError, /stream/)
    expect { described_class.new(digest: "d", payload: {}, stream: "yes", extra: {}) }
      .to raise_error(ArgumentError, /stream/)
  end

  describe "#prefix_digests" do
    # nil = not computed; [] = computed, zero markers. The offline rewrite
    # projection needs that distinction on the wire, so absence is a
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
      expect(chained).to be_deeply_frozen
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
