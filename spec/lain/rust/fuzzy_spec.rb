# frozen_string_literal: true

# The Rust fuzzy matcher (`nucleo-matcher`, in-process under the ext's
# placement rules): a candidate set is built ONCE and matched many times, which
# is the shape completion has -- the candidates change when the workspace does,
# the query changes on every keystroke.
#
# Three properties this file is the authority on, because Rust's own tests
# cannot see them:
#
#   * the boundary is crossed once per batch -- `.new` takes the whole candidate
#     Array, `#match` returns the whole ranked result, and nothing is per-element;
#   * the handle is deeply frozen and Ractor-shareable, which is a claim about
#     the WRAPPER only. The matcher's 135 KB scratch buffer is thread-local and
#     unreachable from the object, precisely so this stays true;
#   * positions index GRAPHEME CLUSTERS, so `candidate.grapheme_clusters` is the
#     sequence a highlighter must slice -- not `chars`, not bytes.
RSpec.describe Lain::Ext::Fuzzy do
  let(:paths) { ["lib/lain/frontend/tty.rb", "lib/lain/tools/bash.rb"] }

  describe ".new" do
    it "returns a frozen, Ractor-shareable handle" do
      expect(described_class.new(paths)).to be_deeply_frozen
    end

    it "keeps the candidates, frozen and in insertion order" do
      fuzzy = described_class.new(paths)
      expect(fuzzy.candidates).to eq(paths)
      expect(fuzzy.candidates).to be_frozen
      expect(fuzzy.size).to eq(2)
    end

    it "accepts an empty candidate set" do
      expect(described_class.new([]).match("anything")).to eq([])
    end

    it "refuses a candidate longer than the matcher's bound" do
      expect { described_class.new(["x" * 100_000]) }
        .to raise_error(described_class::CandidateTooLong, /100000/)
    end

    it "refuses a non-String candidate loudly" do
      expect { described_class.new([42]) }.to raise_error(TypeError, /Integer/)
    end

    # NUL is valid UTF-8, so byte validation alone cannot catch a String whose
    # ENCODING declares a different meaning for the same bytes. See the
    # `read_text` policy comment in `fuzzy.rs`.
    it "refuses a String whose encoding is not byte-transparent" do
      expect { described_class.new(["abc".encode("UTF-16LE")]) }
        .to raise_error(EncodingError, /UTF-16LE/)
    end
  end

  describe "#match" do
    subject(:fuzzy) { described_class.new(paths) }

    it "ranks the frontend path first for `ttyrb`" do
      hits = fuzzy.match("ttyrb")
      expect(hits.first["candidate"]).to eq("lib/lain/frontend/tty.rb")
    end

    it "orders by descending score when both candidates match" do
      scores = fuzzy.match("lainrb").map { |hit| hit["score"] }
      expect(scores.size).to eq(2)
      expect(scores).to eq(scores.sort.reverse)
    end

    it "names the character positions that matched" do
      hit = fuzzy.match("tty").first
      candidate = hit["candidate"]
      matched = hit["positions"].map { |i| candidate.grapheme_clusters[i] }
      expect(matched.join).to eq("tty")
      expect(hit["positions"]).to eq(hit["positions"].sort.uniq)
    end

    it "carries the index of the candidate in the original Array" do
      hit = fuzzy.match("bash").first
      expect(hit["index"]).to eq(1)
      expect(paths[hit["index"]]).to eq(hit["candidate"])
    end

    it "excludes a candidate the query does not match" do
      expect(fuzzy.match("zzzz")).to eq([])
    end

    it "returns deeply frozen hits" do
      expect(fuzzy.match("tty").first).to be_deeply_frozen
    end

    it "crosses the boundary once for five hundred candidates" do
      candidates = Array.new(500) { |i| format("lib/lain/thing_%03d.rb", i) }
      hits = described_class.new(candidates).match("thing")
      expect(hits.size).to eq(500)
      expect(hits.map { |hit| hit["candidate"] }).to match_array(candidates)
    end

    it "breaks ties deterministically" do
      tied = described_class.new(%w[alpha/x.rb beta/x.rb gamma/x.rb])
      first = tied.match("x.rb")
      second = tied.match("x.rb")
      expect(first).to eq(second)
      expect(first.map { |hit| hit["score"] }.uniq.size).to eq(1)
      expect(first.map { |hit| hit["index"] }).to eq([0, 1, 2])
    end

    it "bounds the result count by limit:" do
      candidates = Array.new(20) { |i| "thing_#{i}.rb" }
      expect(described_class.new(candidates).match("thing", limit: 5).size).to eq(5)
    end

    it "treats a nil or absent limit: as every hit" do
      expect(fuzzy.match("rb", limit: nil).size).to eq(2)
      expect(fuzzy.match("rb").size).to eq(2)
      expect(fuzzy.match("rb", limit: 0)).to eq([])
    end

    # Every other argument in this binding fails loudly and names itself. These
    # three used to be the exception: `1.5` truncated silently, and `-1` raised a
    # RangeError that never said `limit:`.
    it "refuses a fractional limit: rather than truncating it" do
      expect { fuzzy.match("rb", limit: 1.5) }
        .to raise_error(TypeError, /limit:.*Integer.*Float/)
    end

    it "refuses a negative limit:, naming it" do
      expect { fuzzy.match("rb", limit: -1) }
        .to raise_error(ArgumentError, /limit:.*negative.*-1/)
    end

    it "refuses a limit: too large to be a count, naming it" do
      expect { fuzzy.match("rb", limit: 2**70) }
        .to raise_error(RangeError, /limit:/)
    end

    it "returns every candidate in order for an empty query" do
      expect(fuzzy.match("").map { |hit| hit["candidate"] }).to eq(paths)
    end

    it "refuses a query longer than the matcher's bound" do
      expect { fuzzy.match("q" * 5_000) }
        .to raise_error(described_class::QueryTooLong, /5000/)
    end

    # `Pattern::parse` gives fzf's query language for free; pinning two operators
    # is what stops a later `Pattern::new` swap from silently changing the syntax
    # the completion UI advertises.
    it "understands fzf's `^prefix` anchor" do
      expect(fuzzy.match("^lib").size).to eq(2)
      expect(fuzzy.match("^tty")).to eq([])
    end

    it "understands fzf's `!` negation" do
      hits = fuzzy.match("rb !tools")
      expect(hits.map { |hit| hit["candidate"] }).to eq(["lib/lain/frontend/tty.rb"])
    end

    # Upstream splits atoms on the SPACE character only, so a tab is a literal
    # char to match and finds nothing. Pinned because a line editor will hand us
    # whatever the user typed, and this is the surprise.
    it "treats a tab as a literal character, not an AND separator" do
      expect(fuzzy.match("lib frontend").size).to eq(1)
      expect(fuzzy.match("lib\tfrontend")).to eq([])
    end

    # Grapheme clusters, not codepoints: "e" + U+0301 COMBINING ACUTE is TWO
    # codepoints and ONE position. A highlighter that sliced by `chars` would
    # cut between the letter and its accent.
    it "indexes grapheme clusters, so a combining mark is one position" do
      decomposed = "néon.rb"
      hit = described_class.new([decomposed]).match("non").first

      expect(decomposed.size).to eq(8)
      expect(decomposed.grapheme_clusters.size).to eq(7)
      expect(hit["positions"]).to all(be < 7)
      expect(hit["positions"].map { |i| decomposed.grapheme_clusters[i] }.join).to eq("non")
    end
  end

  describe "the errors" do
    it "subclass Lain::Error" do
      expect(described_class::CandidateTooLong.ancestors).to include(Lain::Error)
      expect(described_class::QueryTooLong.ancestors).to include(Lain::Error)
    end
  end

  # `Ractor.shareable?` is true, and calling a method off the main Ractor still
  # raises -- no binding in this crate calls `rb_ext_ractor_safe`. Pinned so the
  # gap is a recorded fact rather than a surprise, and so that whoever closes it
  # crate-wide has a test that flips. `Bm25` behaves identically, which is what
  # makes this pre-existing rather than a property of Fuzzy.
  describe "Ractor usability, which shareability does not imply" do
    subject(:fuzzy) { described_class.new(paths) }

    it "is shareable" do
      expect(Ractor.shareable?(fuzzy)).to be(true)
    end

    it "still raises when a method is called off the main Ractor" do
      expect { Ractor.new(fuzzy) { |handle| handle.match("tty") }.value }
        .to raise_error(Ractor::RemoteError)
    end
  end
end
