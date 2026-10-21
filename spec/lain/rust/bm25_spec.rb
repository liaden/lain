# frozen_string_literal: true

# The Rust BM25 index (`bm25` crate, in-process under the ext's data-structure
# placement rules): built once from a batch of [id, text] pairs, immutable after
# build. Retrieval is deterministic and explainable -- each hit carries the
# surface tokens shared by query and document, and equal-score ties break by
# build-batch insertion order so results are byte-identical across processes.
RSpec.describe Lain::Ext::Bm25 do
  # A tiny drug-mention corpus: exactly one document names the rare term.
  def corpus
    [
      ["mat", "the cat sat on the mat"],
      ["dact", "dactinomycin is an antineoplastic chemotherapy drug"],
      ["imat", "imatinib treats chronic myeloid leukemia"],
      ["aspirin", "aspirin is a common analgesic and antiplatelet agent"]
    ]
  end

  describe ".build" do
    it "returns a frozen, Ractor-shareable index" do
      index = described_class.build(corpus)
      expect(index).to be_deeply_frozen
    end

    it "raises EmptyCorpus on an empty batch" do
      expect { described_class.build([]) }
        .to raise_error(described_class::EmptyCorpus)
    end

    it "raises DuplicateId when two pairs share an id" do
      expect { described_class.build([%w[x one], %w[x two]]) }
        .to raise_error(described_class::DuplicateId, /x/)
    end
  end

  describe "#search" do
    subject(:index) { described_class.build(corpus) }

    it "returns [id, score, matched_tokens] triples" do
      hit = index.search("dactinomycin", 5).first
      id, score, matched = hit
      expect(id).to eq("dact")
      expect(score).to be_a(Float).and be > 0.0
      expect(matched).to include("dactinomycin")
    end

    it "returns the exact-term document as the top hit" do
      results = index.search("dactinomycin", 5)
      expect(results.first[0]).to eq("dact")
      expect(results.first[2]).to include("dactinomycin")
    end

    it "bounds the result count by k" do
      expect(index.search("the drug agent", 2).size).to be <= 2
    end

    it "ranks by descending score" do
      scores = index.search("drug agent chemotherapy", 10).map { |hit| hit[1] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it "is empty when the query shares no tokens with any document" do
      expect(index.search("zzznonexistent qqquux", 5)).to eq([])
    end

    # Every other binding in this ext hands back a frozen outer Array
    # (astgrep, treesitter, fuzzy, prompt); a caller must not have to remember
    # which one is the exception. The triples and their token Arrays were
    # already frozen, so this closes the last mutable layer -- and it is what
    # makes the whole result Ractor-shareable, not just deep-frozen by eye.
    it "returns a deeply frozen result, like every sibling binding" do
      expect(index.search("drug chemotherapy agent", 10)).to be_deeply_frozen
    end

    it "freezes the empty result too" do
      expect(index.search("zzznonexistent qqquux", 5)).to be_frozen
    end

    it "is byte-identical across two builds from the same pairs" do
      a = described_class.build(corpus).search("drug chemotherapy agent", 10)
      b = described_class.build(corpus).search("drug chemotherapy agent", 10)
      expect(a).to eq(b)
    end

    it "breaks equal-score ties by build-batch insertion order" do
      # Two documents identical but for id, inserted first-then-second, tie on
      # any shared query token; the earlier-inserted id must rank first, stably.
      tied = described_class.build([
                                     ["first", "identical body text here"],
                                     ["second", "identical body text here"]
                                   ])
      ids = tied.search("identical body text", 5).map { |hit| hit[0] }
      expect(ids).to eq(%w[first second])
    end
  end

  # The build and the search run with the GVL released, because another Ruby thread runs
  # meanwhile, and an interrupt reaches the work, only while the GVL is not held. A build over
  # this many documents takes a few hundred milliseconds and a search a few dozen, long
  # enough for both to show.
  describe "on another thread" do
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def synthetic(count, words = 30)
      rng = Random.new(1)
      vocabulary = Array.new(4000) { |i| "w#{i.to_s(36)}" }
      Array.new(count) { |i| ["d#{i}", Array.new(words) { vocabulary[((rng.rand**2) * 4000).to_i] }.join(" ")] }
    end

    let(:pairs) { synthetic(20_000) }
    # Few long documents, so most of a build is the index work that runs unlocked and little is
    # the copy-in that cannot be interrupted.
    let!(:long_pairs) { synthetic(1_500, 400) }

    def building
      batch = long_pairs
      Thread.new do
        Thread.current.report_on_exception = false
        described_class.build(batch)
      end
    end

    it "ranks a recorded corpus exactly as before the lock was released" do
      index = described_class.build(synthetic(2_000))
      ranked = ["w0 w1 w2", "w3 w9 wz", "w40 w7", "nothing here"].map { |query| index.search(query, 25) }

      expect(Lain::Canonical.digest(ranked))
        .to eq("blake3:53ba3d2aa5165958cc50b890a256f4bd4c7eddea95e250b597da9a9eace0ccd0")
    end

    it "lets the calling thread keep running while it builds" do
      worker = building
      ticks = 0
      (ticks += 1) && sleep(0.001) while worker.alive?

      expect(worker.value).to be_a(described_class)
      expect(ticks).to be >= 20
    end

    it "lets the calling thread keep running while it searches" do
      index = described_class.build(pairs)
      worker = Thread.new { Array.new(10) { index.search("w0 w1 w2", 10) } }
      ticks = 0
      (ticks += 1) && sleep(0.001) while worker.alive?

      expect(worker.value.map(&:size)).to all(eq(10))
      expect(ticks).to be >= 20
    end

    # The card's 20 ms was met in bench-stats; this bound allows for suite load and stays well under the
    # roughly 600 ms a build holding the GVL would take.
    # Timed from when the interrupt was meant to land: a build holding the GVL also keeps
    # this thread's sleep from ending, so its interrupt reaches a thread that is nearly done.
    it "stops within 100 ms of its thread being killed, rather than at the end of the build" do
      GC.start # a collection pause inside the window would count against the bound
      meant = monotonic + 0.05
      worker = building
      sleep 0.05
      expect(worker).to be_alive
      worker.kill.join

      expect(monotonic - meant).to be < 0.1
    end

    it "raises the interrupt's error within 100 ms, rather than returning a partial index" do
      GC.start # a collection pause inside the window would count against the bound
      meant = monotonic + 0.05
      worker = building
      sleep 0.05
      expect(worker).to be_alive
      worker.raise(IOError, "stopped")

      expect { worker.value }.to raise_error(IOError, "stopped")
      expect(monotonic - meant).to be < 0.1
    end

    it "builds the whole index when an interrupt that raises nothing lands mid-build" do
      worker = building
      sleep 0.05
      expect(worker).to be_alive
      worker.wakeup

      expect(worker.value.search("w0", 5).size).to eq(5)
    end

    it "still finishes under a stream of interrupts that raise nothing, since its restarts are bounded" do
      worker = building
      waker = Thread.new do
        while worker.alive?
          sleep 0.001
          worker.wakeup
        end
      rescue ThreadError
        nil
      end

      expect(worker.join(30)).to eq(worker)
      expect(worker.value.search("w0", 5).size).to eq(5)
    ensure
      waker&.kill&.join
    end

    # Releasing hands the lock to a busy thread, and getting it back waits out that thread's time
    # slice, about 20 ms; the bound is loose for a loaded suite and well under a slice.
    it "keeps the lock for a small build and search, so a busy offload-priority thread does not slow them" do
      small = synthetic(100)
      busy = Thread.new do
        Thread.current.priority = Lain::Tool::Offload::PRIORITY
        loop { nil }
      end
      sleep 0.05
      index = described_class.build(small)
      started = monotonic
      20.times { described_class.build(small) }
      built = (monotonic - started) / 20
      started = monotonic
      20.times { index.search("w0 w1 w2", 10) }
      searched = (monotonic - started) / 20

      expect([built, searched]).to all(be < 0.008)
    ensure
      busy&.kill&.join
    end

    it "answers every build when more run at once than it has slots for" do
      small = synthetic(500)
      sizes = Array.new(80) { Thread.new { described_class.build(small).search("w0", 3).size } }.map(&:value)

      expect(sizes).to all(eq(3))
    end

    it "still names the refusal of a degenerate batch when built on another thread" do
      error = Thread.new { described_class.build([%w[x one], %w[x two]]) }
      expect { error.value }.to raise_error(described_class::DuplicateId, /x/)
    end
  end
end
