# frozen_string_literal: true

RSpec.describe Lain::Bench::HotPaths do
  let(:row_names) do
    %w[
      render_chat_10 render_cold_10 bash_true_none bash_true_traced bash_true_reader request_1000
      journal_small journal_1000 mask_first_output wire_ready
    ]
  end

  def row(name, median, skipped: nil, spread: 0.5)
    Lain::Bench::HotPaths::Row.new(name:, median_ms: skipped ? nil : median, spread_ms: skipped ? nil : spread, reps: 3,
                                   skipped:)
  end

  describe "#rows at a tiny size" do
    let(:rows) do
      NetworkAccess.permit { described_class.new(turns: 10, reps: 1, sizes: [1_000]).rows }
    end

    it "returns one row per measured path, in the table's order", :seam do
      expect(rows.map(&:name)).to eq(row_names)
    end

    it "gives every row a median and a spread, or a reason it was skipped", :seam do
      expect(rows).to all(satisfy { |r|
        r.skipped.nil? ? [r.median_ms, r.spread_ms].all?(Float) : r.skipped.is_a?(String)
      })
    end

    it "reports the repetitions it was asked for", :seam do
      expect(rows.reject(&:skipped).map(&:reps)).to all(eq(1))
    end
  end

  describe "a box without bwrap" do
    let(:probe) do
      instance_double(Lain::Confine::Probe, fence_gap: nil, fence_unstartable?: false).tap do |probe|
        allow(probe).to receive(:supports?) { |layer| layer != :bwrap }
      end
    end

    it "skips the reader row by name and measures none of its time", :seam do
      rows = NetworkAccess.permit { described_class.new(turns: 10, reps: 1, sizes: [1_000], probe:).rows }
      reader = rows.find { _1.name == "bash_true_reader" }

      expect(reader).to have_attributes(skipped: "no bwrap", median_ms: nil)
    end
  end

  describe "the measured fixture" do
    it "pins what a render is measured over, so a card cannot change it unseen" do
      expect(described_class::Corpus.cold_request(turns: 10).digest)
        .to eq("blake3:50970980eb367381c15cc69fd0fda5b8f2d075660fe5211275670bcf9cbbe2be")
    end
  end

  describe "the clock" do
    it "times each repetition with the injected clock" do
      ticks = [0.0, 0.001, 0.0, 0.003, 0.0, 0.002].each
      timed = described_class.new(turns: 10, reps: 3, sizes: [1_000], clock: -> { ticks.next })

      expect(timed.measure(3) { nil }).to have_attributes(median_ms: 2.0, spread_ms: 1.0, reps: 3)
    end
  end

  describe described_class::Sweep do
    it "takes each row's median across the runs and their spread as the layout noise" do
      merged = described_class.merge([[row("a", 10.0)], [row("a", 12.0)], [row("a", 11.0)]])

      expect(merged).to contain_exactly(have_attributes(name: "a", median_ms: 11.0, spread_ms: 2.0))
    end

    it "keeps a row skipped when any run skipped it" do
      merged = described_class.merge([[row("a", 10.0)], [row("a", 0, skipped: "no bwrap")]])

      expect(merged.first).to have_attributes(skipped: "no bwrap", median_ms: nil)
    end
  end

  describe described_class::Log do
    let(:log) do
      described_class.new(rows: [row("a", 1.5), row("b", 0, skipped: "no bwrap")], sha: "abc123",
                          loadavg: "0.10 0.20 0.30", workers: "12")
    end

    it "reads back what it wrote" do
      expect(described_class.parse(log.dump)).to eq(log)
    end

    it "names the sha, the loadavg and the worker count" do
      expect(log.dump).to include("abc123", "0.10 0.20 0.30", "12")
    end
  end

  describe described_class::Records do
    let(:dir) { Dir.mktmpdir("hot-path-records") }

    after { FileUtils.rm_rf(dir) }

    it "keeps the last 3 logs" do
      records = described_class.new(dir:)
      5.times { |i| records.write("log #{i}") }

      expect(records.texts).to eq(["log 2", "log 3", "log 4"])
    end

    it "creates its directory" do
      nested = File.join(dir, "deeper", "logs")
      described_class.new(dir: nested).write("one")

      expect(Dir.children(nested).size).to eq(1)
    end
  end

  describe described_class::Check do
    let(:ceilings) { { "render_chat_10k" => 40.0, "bash_true_reader" => 10.0 } }

    def logs(chat, reader = [5.0, 5.0, 5.0])
      chat.zip(reader).map do |c, r|
        [row("render_chat_10k", c),
         r.is_a?(String) ? row("bash_true_reader", 0, skipped: r) : row("bash_true_reader", r)]
      end
    end

    it "passes when each row is at or under its ceiling in at least 2 of 3 logs" do
      expect(described_class.new(ceilings).failures(logs([39.0, 45.0, 40.0]))).to be_empty
    end

    it "names the row, its ceiling and the 3 medians when it is over in 2 of 3" do
      expect(described_class.new(ceilings).failures(logs([41.0, 42.0, 30.0])))
        .to eq(["render_chat_10k is over its 40.0 ms ceiling in 2 of 3 logs (medians 41.0, 42.0, 30.0 ms)"])
    end

    it "does not count a skipped row as a pass" do
      expect(described_class.new(ceilings).failures(logs([1.0, 1.0, 1.0], ["no bwrap", "no bwrap", 5.0])))
        .to eq(["bash_true_reader is under its 10.0 ms ceiling in only 1 of 3 logs " \
                "(medians skipped: no bwrap, skipped: no bwrap, 5.0 ms)"])
    end

    it "fails on fewer than 3 logs" do
      expect(described_class.new(ceilings).failures(logs([1.0, 1.0, 1.0]).first(2)))
        .to include("need 3 recorded logs, found 2")
    end

    it "fails on a row whose ceiling is not seeded yet" do
      expect(described_class.new({ "render_chat_10k" => nil }).failures(logs([1.0, 1.0, 1.0])))
        .to eq(["render_chat_10k has no ceiling; seed it from 3 quiet-box logs"])
    end
  end
end
