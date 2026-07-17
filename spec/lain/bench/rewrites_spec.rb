# frozen_string_literal: true

require "json"

# Rewrites is an OFFLINE projection over a Journal's `request_sent` records
# (CE-2): it recreates `diverge_at` at the request level, over the
# breakpoint-partitioned chain `Request#prefix_digests` already computes and
# `Telemetry::RequestSent` already journals -- no Timeline access, journal bytes
# only.
#
# Rewrite semantics (binding, from the T4 card): a REWRITE is a position
# present in BOTH of two consecutive chains but carrying a DIFFERENT digest;
# its DEPTH is the smallest such position. A position present in only one
# chain -- a marker slid, or a message got appended -- is NOT a rewrite.
RSpec.describe Lain::Bench::Rewrites do
  # `chain` is an Array of [position, digest] pairs, exactly the shape
  # `Request#prefix_digests` returns and `Telemetry::RequestSent#prefix_digests`
  # journals; `nil` reproduces "not computed" (an older Journal, or a run that
  # never enabled the chain).
  def record(chain)
    { "type" => "request_sent", "digest" => "blake3:req", "payload" => {}, "stream" => true,
      "extra" => {}, "prefix_digests" => chain }
  end

  describe ".from_journal" do
    it "reports the rewrite count, each rewrite's depth, and the digests either side of the divergence" do
      before = [[-1, "blake3:sys"], [0, "blake3:msg0"], [3, "blake3:msg3"]]
      after = [[-1, "blake3:sys"], [0, "blake3:msg0-EDITED"], [3, "blake3:msg3-EDITED"]]

      rewrites = described_class.from_journal([record(before), record(after)])

      expect(rewrites.count).to eq(1)
      rewrite = rewrites.first
      expect(rewrite.depth).to eq(0)
      expect(rewrite.from_digest).to eq("blake3:msg0")
      expect(rewrite.to_digest).to eq("blake3:msg0-EDITED")
    end

    it "attributes depth as the SMALLEST differing shared position, not merely any differing one" do
      before = [[0, "blake3:a"], [2, "blake3:b"], [5, "blake3:c"]]
      after = [[0, "blake3:a"], [2, "blake3:b-EDITED"], [5, "blake3:c-EDITED"]]

      rewrite = described_class.from_journal([record(before), record(after)]).first

      expect(rewrite.depth).to eq(2)
      expect(rewrite.from_digest).to eq("blake3:b")
      expect(rewrite.to_digest).to eq("blake3:b-EDITED")
    end

    it "reports zero rewrites when every shared position agrees, even as markers slide and the tail grows" do
      before = [[0, "blake3:a"], [15, "blake3:b"]]
      after = [[0, "blake3:a"], [30, "blake3:b"], [45, "blake3:c"]]

      rewrites = described_class.from_journal([record(before), record(after)])

      expect(rewrites.count).to eq(0)
      expect(rewrites.to_a).to eq([])
    end

    it "reports zero rewrites for two chains that share no positions at all" do
      before = [[0, "blake3:a"]]
      after = [[7, "blake3:z"]]

      expect(described_class.from_journal([record(before), record(after)]).count).to eq(0)
    end

    it "skips a nil (not-computed) chain entirely, rather than treating it as a gap between real chains" do
      first = [[0, "blake3:a"]]
      last = [[0, "blake3:a-EDITED"]]

      rewrites = described_class.from_journal([record(first), record(nil), record(last)])

      expect(rewrites.count).to eq(1)
      expect(rewrites.first.from_digest).to eq("blake3:a")
      expect(rewrites.first.to_digest).to eq("blake3:a-EDITED")
    end

    it "processes a computed-EMPTY chain ([]) normally: it shares no positions, so it can only rule a rewrite out" do
      rewrites = described_class.from_journal([record([]), record([[0, "blake3:a"]])])

      expect(rewrites.count).to eq(0)
    end

    it "finds no rewrite across a single record -- there is no consecutive pair to compare" do
      expect(described_class.from_journal([record([[0, "blake3:a"]])]).count).to eq(0)
    end

    it "finds no rewrite over an empty journal" do
      expect(described_class.from_journal([]).count).to eq(0)
    end

    it "keeps only request_sent records out of a mixed NDJSON stream, in journal order" do
      lines = [
        JSON.generate(record([[0, "blake3:a"]])),
        JSON.generate("type" => "turn_usage", "digest" => "blake3:req", "model" => "x",
                      "stop_reason" => "end_turn", "usage" => { "input_tokens" => 1, "output_tokens" => 1 }),
        "not json at all {",
        JSON.generate(record([[0, "blake3:a-EDITED"]]))
      ]

      rewrites = described_class.from_journal(lines)

      expect(rewrites.count).to eq(1)
      expect(rewrites.first.to_digest).to eq("blake3:a-EDITED")
    end

    # PINNED CONFLATION, not an aspiration: `Request#prefix_digests` folds
    # `model` into every entry (CE-2's chains are per-model by design), so a
    # model switch between consecutive calls disagrees at EVERY shared
    # position and this projection reports it as one Rewrite at the earliest
    # one -- indistinguishable, from the chains alone, from a real prefix
    # edit. Chains are built through the real Request here so the pin breaks
    # if T2 ever changes what the digests cover. Callers comparing across
    # models must segment the journal per arm first (see the class comment).
    it "reports a plain model switch as one Rewrite at the earliest shared position (per-model chains)" do
      chains = %w[claude-opus-4-8 claude-haiku-4-8].map do |model|
        Lain::Request.new(
          model:,
          system: [{ "type" => "text", "text" => "be terse", "cache" => true }],
          messages: [{ "role" => "user",
                       "content" => [{ "type" => "text", "text" => "hi", "cache" => true }] }],
          max_tokens: 64
        ).prefix_digests
      end

      rewrites = described_class.from_journal(chains.map { |chain| record(chain) })

      expect(rewrites.count).to eq(1)
      expect(rewrites.first.depth).to eq(Lain::Request::SYSTEM_PREFIX)
    end

    it "compares only CONSECUTIVE calls: a rewrite that reverts on the third call is one rewrite, not zero" do
      a = [[0, "blake3:a"]]
      b = [[0, "blake3:a-EDITED"]]

      rewrites = described_class.from_journal([record(a), record(b), record(a)])

      expect(rewrites.count).to eq(2)
      expect(rewrites.map(&:from_digest)).to eq(["blake3:a", "blake3:a-EDITED"])
      expect(rewrites.map(&:to_digest)).to eq(["blake3:a-EDITED", "blake3:a"])
    end
  end

  # R.1: the rolling chain (format 2) changed every recorded digest VALUE, so
  # the record carries `prefix_chain_version` and this projection dual-reads --
  # old unversioned journals localize divergence exactly as before, new ones
  # under the version tag, and the two formats are never compared to each
  # other (their digests disagree everywhere by construction; reporting that
  # as a rewrite would misread the migration as a prompt edit).
  describe "chain format dual-read (R.1)" do
    def versioned_record(chain)
      record(chain).merge("prefix_chain_version" => Lain::Request::PREFIX_CHAIN_VERSION)
    end

    # Format 1, emulated: the retired whole-stripped-prefix digest per marker.
    # Executable HERE because lib no longer computes it -- this is the
    # dual-read suite's definition of "old recorded journal", and the frozen
    # corpus below pins it against real recorded bytes. Final-block markers
    # only, so block truncation never enters.
    def legacy_chain(request)
      request.prefix_digests.map(&:first).map do |position|
        slice = position == Lain::Request::SYSTEM_PREFIX ? [] : request.messages.first(position + 1)
        [position, Lain::Canonical.digest(
          "model" => request.model, "tools" => strip(request.tools),
          "system" => strip(request.system), "messages" => strip(slice)
        )]
      end
    end

    def strip(value)
      case value
      when Hash then value.except("cache").transform_values { |v| strip(v) }
      when Array then value.map { |v| strip(v) }
      else value
      end
    end

    # One session as a Request: two shared turns, every message marked, the
    # third turn carrying the divergence.
    def session_diverging_at_two(final_text)
      shared = [
        { "role" => "user", "content" => [{ "type" => "text", "text" => "m0", "cache" => true }] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "m1", "cache" => true }] }
      ]
      diverging = { "role" => "user", "content" => [{ "type" => "text", "text" => final_text, "cache" => true }] }
      Lain::Request.new(model: "claude-opus-4-8", messages: shared + [diverging], max_tokens: 64)
    end

    it "localizes two sessions' divergence at the same position under old and new formats" do
      a = session_diverging_at_two("diverges-a")
      b = session_diverging_at_two("diverges-b")

      old_format = described_class.from_journal([record(legacy_chain(a)), record(legacy_chain(b))])
      new_format = described_class.from_journal([versioned_record(a.prefix_digests),
                                                 versioned_record(b.prefix_digests)])

      expect(old_format.count).to eq(1)
      expect(new_format.count).to eq(1)
      expect(old_format.first.depth).to eq(2)
      expect(new_format.first.depth).to eq(old_format.first.depth)
    end

    it "treats a format boundary as incomparable, never as a rewrite" do
      req = session_diverging_at_two("same bytes both sides")
      migration = [record(legacy_chain(req)), versioned_record(req.prefix_digests)]

      expect(described_class.from_journal(migration).count).to eq(0)
    end

    it "still skips a nil (not-computed) chain regardless of its neighbors' formats" do
      req = session_diverging_at_two("same bytes both sides")
      entries = [versioned_record(req.prefix_digests), record(nil), versioned_record(req.prefix_digests)]

      expect(described_class.from_journal(entries).count).to eq(0)
    end

    # The frozen corpus is REAL recorded bytes (see its README): copies of the
    # variance fixtures made before the rolling chain landed, never
    # regenerated. Old journals staying loadable is the acceptance criterion,
    # proven against bytes no current writer can produce.
    describe "the frozen v1 corpus (spec/fixtures/sessions/rewrites_v1)" do
      let(:corpus_dir) { File.expand_path("../../fixtures/sessions/rewrites_v1", __dir__) }

      it "reads a whole recorded v1 session and finds no false rewrite as its markers slide" do
        rewrites = described_class.from_journal(File.foreach(File.join(corpus_dir, "one.ndjson")))

        expect(rewrites.count).to eq(0)
      end

      it "localizes real divergence between two recorded v1 sessions of the one task" do
        # Sessions one and two share their first model call and diverge from
        # the tool_use on, so their second requests disagree at position 2
        # (the tool_result turn) and agree at the shared system marker (-1).
        second_requests = %w[one two].map do |name|
          File.foreach(File.join(corpus_dir, "#{name}.ndjson"))
              .select { |line| line.include?('"type":"request_sent"') }.last
        end
        rewrites = described_class.from_journal(second_requests)

        expect(rewrites.count).to eq(1)
        expect(rewrites.first.depth).to eq(2)
      end
    end
  end

  describe "Enumerable" do
    it "is enumerable over its Rewrite values" do
      rewrites = described_class.from_journal([record([[0, "blake3:a"]]), record([[0, "blake3:b"]])])

      expect(rewrites).to be_a(Enumerable)
      expect(rewrites.map(&:depth)).to eq([0])
    end
  end

  describe "immutability" do
    it "is deeply frozen and Ractor-shareable" do
      rewrites = described_class.from_journal([record([[0, "blake3:a"]]), record([[0, "blake3:b"]])])

      expect(rewrites).to be_deeply_frozen
    end
  end
end
