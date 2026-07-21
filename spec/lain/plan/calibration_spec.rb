# frozen_string_literal: true

# PC-5: folds `closure_record` journal pointers (Plan::Closure#record, P2) --
# the pointer that survives the Store's process, so calibration works from the
# Journal alone across sessions -- into per-size-class turn/token
# distributions. `#median_turns(size_class)` is P4's `calibration:` input; a
# class with no history answers nil, the annotation-only fallback.
RSpec.describe Lain::Plan::Calibration do
  # A closure_record line as Plan::Closure#record actually journals it (see
  # spec/lain/plan/closure_spec.rb) -- raw Hash, the Journal.records duck,
  # never reconstructed through Telemetry::ClosureRecord (whose Guard demands
  # `size`, so a pre-migration line without it could never become one).
  def closure_record(step_id:, size:, digests:)
    record = { "type" => "closure_record", "closure_digest" => "blake3:closure-#{step_id}",
               "step_id" => step_id, "plan_digest" => "blake3:plan", "chunk_turn_digests" => digests }
    size.nil? ? record : record.merge("size" => size)
  end

  # 10 in, 5 out -> 15 total tokens per turn, the same fixture shape
  # spec/lain/ledger_spec.rb uses.
  def turn_usage(digest)
    { "type" => "turn_usage", "digest" => digest, "model" => "claude-sonnet-4", "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => 10, "output_tokens" => 5,
                   "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
  end

  def turns_for(digests)
    digests.map { |digest| turn_usage(digest) }
  end

  # Six closure_record entries across S and M -- the AC's own fixture shape.
  # S: turns [1, 2, 1] -> median 1, tokens [15, 30, 15] -> median 15.
  # M: turns [3, 2, 4] -> median 3, tokens [45, 30, 60] -> median 45.
  let(:s1) { %w[s1t1] }
  let(:s2) { %w[s2t1 s2t2] }
  let(:s3) { %w[s3t1] }
  let(:m1) { %w[m1t1 m1t2 m1t3] }
  let(:m2) { %w[m2t1 m2t2] }
  let(:m3) { %w[m3t1 m3t2 m3t3 m3t4] }

  let(:classed_entries) do
    [
      closure_record(step_id: "S1", size: "S", digests: s1),
      closure_record(step_id: "S2", size: "S", digests: s2),
      closure_record(step_id: "S3", size: "S", digests: s3),
      closure_record(step_id: "M1", size: "M", digests: m1),
      closure_record(step_id: "M2", size: "M", digests: m2),
      closure_record(step_id: "M3", size: "M", digests: m3),
      *turns_for(s1), *turns_for(s2), *turns_for(s3),
      *turns_for(m1), *turns_for(m2), *turns_for(m3)
    ]
  end

  describe ".fold" do
    it "renders per-class turn and token distributions and answers median_turns for each class" do
      calibration = described_class.fold(classed_entries)

      expect(calibration.median_turns("S")).to eq(1)
      expect(calibration.median_turns("M")).to eq(3)
      expect(calibration.median_tokens("S")).to eq(15)
      expect(calibration.median_tokens("M")).to eq(45)
      expect(calibration.turns_distribution("S").n).to eq(3)
      expect(calibration.tokens_distribution("M").n).to eq(3)
    end

    it "answers nil for a class with no history (the annotation fallback)" do
      calibration = described_class.fold(classed_entries)

      expect(calibration.median_turns("L")).to be_nil
      expect(calibration.median_tokens("L")).to be_nil
      expect(calibration.turns_distribution("L")).to be_nil
    end

    it "answers nil folding an empty journal" do
      calibration = described_class.fold([])

      expect(calibration.median_turns("S")).to be_nil
      expect(calibration.unclassed_count).to eq(0)
    end

    it "accepts a Symbol size class the same as a String" do
      calibration = described_class.fold(classed_entries)

      expect(calibration.median_turns(:S)).to eq(calibration.median_turns("S"))
    end

    describe "a closure_record with no recoverable size (pre-migration line, hand-built fixture)" do
      let(:unclassed_digests) { %w[u1t1] }
      let(:entries) do
        classed_entries + [closure_record(step_id: "U1", size: nil, digests: unclassed_digests),
                           *turns_for(unclassed_digests)]
      end

      it "folds as unclassed: excluded from every per-class distribution" do
        calibration = described_class.fold(entries)

        expect(calibration.median_turns("S")).to eq(1)
        expect(calibration.median_turns("M")).to eq(3)
        expect(calibration.unclassed_count).to eq(1)
      end

      it "names the gap in the report rather than silently dropping it" do
        calibration = described_class.fold(entries)

        expect(calibration.render).to match(/unclassed.*: 1/)
      end
    end

    # Panel finding: Telemetry::ClosureRecord's Guard only checks size's
    # PRESENCE, not its type -- nothing stops a live in-process caller from
    # constructing one with size: :S and handing #to_journal's Hash straight
    # to Calibration without ever passing through JSON (which would have
    # stringified it for free). chunk_from must normalize size the same way
    # regardless of whether it arrived as a Symbol or a String.
    describe "a Symbol-sized closure_record (live in-process Hash, never JSON round-tripped)" do
      def symbol_sized_record(step_id:, size:, digests:)
        Lain::Telemetry::ClosureRecord.new(closure_digest: "blake3:closure-#{step_id}", step_id:,
                                           plan_digest: "blake3:plan", size:,
                                           chunk_turn_digests: digests).to_journal
      end

      it "folds identically to its String twin" do
        symbol_entries = [symbol_sized_record(step_id: "SYM", size: :S, digests: %w[sym1]),
                          *turns_for(%w[sym1])]
        string_entries = [symbol_sized_record(step_id: "STR", size: "S", digests: %w[str1]),
                          *turns_for(%w[str1])]

        symbol_calibration = described_class.fold(symbol_entries)
        string_calibration = described_class.fold(string_entries)

        expect(symbol_calibration.median_turns("S")).to eq(string_calibration.median_turns("S"))
        expect(symbol_calibration.median_tokens("S")).to eq(string_calibration.median_tokens("S"))
        expect(symbol_calibration.unclassed_count).to eq(0)
      end

      it "does not crash #render and does not vanish from either per-class or unclassed accounting" do
        calibration = described_class.fold([symbol_sized_record(step_id: "SYM", size: :S, digests: %w[sym1]),
                                            *turns_for(%w[sym1])])

        expect { calibration.render }.not_to raise_error
        expect(calibration.median_turns("S")).to eq(1)
        expect(calibration.unclassed_count).to eq(0)
      end
    end

    it "is a pure fold: rendering twice yields identical bytes" do
      calibration = described_class.fold(classed_entries)

      expect(calibration.render).to eq(calibration.render)
    end
  end

  describe "#render" do
    it "shows each class's distribution and per-chunk drift against its class median" do
      report = described_class.fold(classed_entries).render

      expect(report).to include("S")
      expect(report).to include("M")
      # M3 measured 4 turns against the M class's median of 3 -- a visible
      # drift line, not a silent average.
      expect(report).to match(/M3.*M.*4.*3\.0/)
    end
  end
end
