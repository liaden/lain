# frozen_string_literal: true

require "stringio"
require "tmpdir"

# PC-2: a step-closure record derived ENTIRELY from content-addressed sources --
# step id/title/status from the plan, criteria pass/fail from the Grade, files +
# blob digests from the snapshot at the seam, and the chunk's turn digests as the
# elided span (they stay in the Store, attested but un-rendered). No model is
# touched: the deterministic tier leaves notes_for_future_steps empty. The record
# is a frozen value put into the Store, and -- because the Store is in-memory per
# process -- every closure ALSO journals a Telemetry::ClosureRecord pointer so a
# later session finds it from the Journal alone.
RSpec.describe Lain::Plan::Closure do
  # A timeline whose chunk carries two erroring tool_result blocks, so the failed
  # path has real error evidence to name. Root-first index (via #to_a):
  #   0 user "go" | 1 assistant tool_use | 2 user two error results + one ok
  def chunk_timeline(store = Lain::Store.new)
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
                  .commit(role: :assistant, content: [{ "type" => "tool_use", "id" => "t1", "name" => "bash",
                                                        "input" => { "cmd" => "false" } }])
                  .commit(role: :user, content: [error_block("t1", "boom"), error_block("t2", "kaboom"),
                                                 { "type" => "tool_result", "tool_use_id" => "t3",
                                                   "content" => "fine", "is_error" => false }])
  end

  def error_block(id, text)
    { "type" => "tool_result", "tool_use_id" => id, "content" => text, "is_error" => true }
  end

  def snapshot_over(timeline)
    dir = Dir.mktmpdir
    path = File.join(dir, "lib.rb")
    File.write(path, "answer = 42")
    [Lain::Workspace::Snapshot.new(root: dir).write(timeline:, paths: [path]), dir]
  end

  let(:timeline) { chunk_timeline }
  let(:step) { Lain::Plan::Step.new(id: "P2", title: "close a chunk", size: "M", status: "done") }
  let(:grade) { Lain::Grader::Grade.new(score: 1.0, pass: true, why: "all criteria met") }
  let(:snapshot) { snapshot_over(timeline).first }

  describe ".build" do
    it "derives every field from a digest, touching no provider, and round-trips from the Store" do
      closure = described_class.build(step:, timeline:, chunk_range: (0..2), grade:, snapshot:)

      expect(closure.step_id).to eq("P2")
      expect(closure.title).to eq("close a chunk")
      expect(closure.status).to eq("done")
      expect(closure.size).to eq("M")
      expect(closure.passed).to be(true)
      expect(closure.score).to eq(1.0)
      expect(closure.files).to eq(snapshot.body.fetch("files"))
      expect(closure.elided_digests).to eq(timeline.to_a[0..2].map(&:digest))
      expect(closure.notes_for_future_steps).to be_empty

      digest = timeline.store.put(closure)
      expect(timeline.store.fetch(digest)).to eq(closure)
    end

    it "derives the S/M/L size class from the step (P5 calibrates over it from the Journal)" do
      large = Lain::Plan::Step.new(id: "P9", title: "big one", size: "L", status: "done")

      closure = described_class.build(step: large, timeline:, chunk_range: (0..2), grade:, snapshot:)

      expect(closure.size).to eq("L")
    end

    it "carries the snapshot's write-set-only scope note verbatim (never implying full coverage)" do
      closure = described_class.build(step:, timeline:, chunk_range: (0..2), grade:, snapshot:)

      expect(closure.snapshot_scope).to eq(Lain::Workspace::Snapshot::SCOPE_NOTE)
    end

    it "leaves error_digests empty for a passing step" do
      closure = described_class.build(step:, timeline:, chunk_range: (0..2), grade:, snapshot:)

      expect(closure.error_digests).to be_empty
    end

    it "closes a failed step richer: the evidence digests name both error result blocks" do
      failed_step = step.with_status("failed")
      failed_grade = Lain::Grader::Grade.new(score: 0.0, pass: false, why: "the suite failed")
      error_turn = timeline.to_a.fetch(2)
      expected = error_turn.content.select { |block| block["is_error"] }.map { |block| Lain::Canonical.digest(block) }

      closure = described_class.build(step: failed_step, timeline:, chunk_range: (0..2),
                                      grade: failed_grade, snapshot:)

      expect(closure.status).to eq("failed")
      expect(closure.passed).to be(false)
      expect(closure.error_digests).to contain_exactly(*expected)
      expect(closure.error_digests.size).to eq(2)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      closure = described_class.build(step:, timeline:, chunk_range: (0..2), grade:, snapshot:)

      expect(Ractor.shareable?(closure)).to be(true)
    end

    # A chunk_range must land fully within the timeline's turns. Left un-guarded,
    # a fully-out-of-bounds range folds (via Array(nil)) into an attested EMPTY
    # span byte-identical to a genuinely-empty chunk, and a negative range
    # silently reinterprets under slice semantics. Both are loud refusals: an
    # elided-span attestation must never be silently wrong.
    describe "chunk_range bounds (loud refusal, never a silent empty span)" do
      it "raises ChunkRangeOutOfBounds naming the range and the timeline length for a fully OOB range" do
        expect { described_class.build(step:, timeline:, chunk_range: (10..12), grade:, snapshot:) }
          .to raise_error(Lain::Plan::ChunkRangeOutOfBounds, /10\.\.12.*\b3\b/m)
      end

      it "raises when only the end overflows (0..99), never clamping to the whole timeline" do
        expect { described_class.build(step:, timeline:, chunk_range: (0..99), grade:, snapshot:) }
          .to raise_error(Lain::Plan::ChunkRangeOutOfBounds, /0\.\.99/)
      end

      it "raises on a negative range rather than reinterpreting it under slice semantics" do
        expect { described_class.build(step:, timeline:, chunk_range: (-2..-1), grade:, snapshot:) }
          .to raise_error(Lain::Plan::ChunkRangeOutOfBounds, /-2\.\.-1/)
      end

      it "raises on the beginless/endless 0..-1 idiom (callers pass absolute indices)" do
        expect { described_class.build(step:, timeline:, chunk_range: (0..-1), grade:, snapshot:) }
          .to raise_error(Lain::Plan::ChunkRangeOutOfBounds)
      end

      it "still builds a legitimately empty in-bounds range (2..1), attesting an empty span" do
        closure = described_class.build(step:, timeline:, chunk_range: (2..1), grade:, snapshot:)

        expect(closure.elided_digests).to eq([])
      end
    end
  end

  describe "#record" do
    it "puts the closure into the Store and journals a closure_record pointer naming it" do
      closure = described_class.build(step:, timeline:, chunk_range: (0..2), grade:, snapshot:)
      journal = []

      digest = closure.record(store: timeline.store, plan_digest: "blake3:plan", journal:)

      expect(timeline.store.fetch(digest)).to eq(closure)
      expect(journal.size).to eq(1)
      pointer = journal.first
      expect(pointer).to be_a(Lain::Telemetry::ClosureRecord)
      expect(pointer.closure_digest).to eq(closure.digest)
      expect(pointer.step_id).to eq("P2")
      expect(pointer.plan_digest).to eq("blake3:plan")
      expect(pointer.size).to eq("M")
      expect(pointer.chunk_turn_digests).to eq(closure.elided_digests)
    end

    it "lets the Journal find every closure built in a session, from the NDJSON alone" do
      io = StringIO.new
      real_journal = Lain::Journal.new(io:)

      first = described_class.build(step:, timeline:, chunk_range: (0..1), grade:, snapshot:)
      second = described_class.build(step: step.with_status("failed"), timeline:, chunk_range: (2..2),
                                     grade: Lain::Grader::Grade.new(score: 0.0, pass: false, why: "nope"),
                                     snapshot:)
      first.record(store: timeline.store, plan_digest: "blake3:plan", journal: real_journal)
      second.record(store: timeline.store, plan_digest: "blake3:plan", journal: real_journal)

      records = Lain::Journal.records(io.string.each_line, type: "closure_record").to_a

      expect(records.size).to eq(2)
      expect(records.map { |record| record.fetch("closure_digest") })
        .to contain_exactly(first.digest, second.digest)
      expect(records.map { |record| record.fetch("step_id") }).to contain_exactly("P2", "P2")
      expect(records.map { |record| record.fetch("size") }).to contain_exactly("M", "M")
      records.each { |record| expect(record.fetch("plan_digest")).to eq("blake3:plan") }
    end
  end

  describe Lain::Telemetry::ClosureRecord do
    it "is Ractor-shareable and journals under the closure_record type, carrying the size class" do
      record = described_class.new(closure_digest: +"blake3:c", step_id: +"P2", plan_digest: +"blake3:p",
                                   size: +"M", chunk_turn_digests: [+"blake3:t1", +"blake3:t2"])

      expect(Ractor.shareable?(record)).to be(true)
      expect(record.to_journal.fetch("type")).to eq("closure_record")
      expect(record.to_journal.fetch("size")).to eq("M")
    end

    it "raises loudly when the closure digest it points at is missing" do
      expect do
        described_class.new(closure_digest: nil, step_id: "P2", plan_digest: "blake3:p", size: "M",
                            chunk_turn_digests: [])
      end.to raise_error(ArgumentError, /closure_digest/)
    end

    it "raises loudly when the size class is missing (P5's calibration key)" do
      expect do
        described_class.new(closure_digest: "blake3:c", step_id: "P2", plan_digest: "blake3:p", size: nil,
                            chunk_turn_digests: [])
      end.to raise_error(ArgumentError, /size/)
    end
  end
end
