# frozen_string_literal: true

# The plan as a deeply frozen, content-addressed value: ordered steps split into
# chunks by author-editable seams, every mutation returning a new value, and two
# renderings -- the live #to_reminder projection (the Workspace tail) and the
# author-editable #to_markdown that round-trips back to the same digest.
RSpec.describe Lain::Plan::Document do
  let(:steps) do
    [
      Lain::Plan::Step.new(id: "s1", title: "First step", size: "M"),
      Lain::Plan::Step.new(id: "s2", title: "Second step", size: "S", criteria_digest: "blake3:abc123"),
      Lain::Plan::Step.new(id: "s3", title: "Third step", size: "L")
    ]
  end

  subject(:document) { described_class.new(steps:) }

  describe Lain::Plan::Step do
    it "rejects an unknown size class loudly" do
      expect { described_class.new(id: "x", title: "t", size: "XL") }
        .to raise_error(ArgumentError, /unknown size/)
    end

    it "rejects an unknown status loudly" do
      expect { described_class.new(id: "x", title: "t", size: "S", status: "wip") }
        .to raise_error(ArgumentError, /unknown status/)
    end

    it "defaults to pending with no criteria digest" do
      step = described_class.new(id: "x", title: "t", size: "S")

      expect(step.status).to eq("pending")
      expect(step.criteria_digest).to be_nil
    end

    it "returns a new value from #with_status rather than mutating" do
      step = described_class.new(id: "x", title: "t", size: "S")
      done = step.with_status("done")

      expect(step.status).to eq("pending")
      expect(done.status).to eq("done")
    end

    it "answers #failed? by its status" do
      step = described_class.new(id: "x", title: "t", size: "S")

      expect(step).not_to be_failed
      expect(step.with_status("failed")).to be_failed
    end

    # S1: the markdown round-trip must be total -- every constructible Step must
    # either round-trip digest-identically OR be refused loudly at construction.
    # These are the shapes the round-trip probe found that the line-oriented,
    # backtick/brace-delimited grammar cannot represent unambiguously; each is
    # rejected naming the offending value and the reserved grammar.
    describe "loud construction guards -- the reserved plan-markdown grammar" do
      it "refuses an empty title" do
        expect { described_class.new(id: "s1", title: "", size: "M") }
          .to raise_error(Lain::Plan::MalformedStep, /empty/)
      end

      it "refuses a title containing a newline, naming the value" do
        expect { described_class.new(id: "s1", title: "line1\nline2", size: "M") }
          .to raise_error(Lain::Plan::MalformedStep, /line1.*line2/m)
      end

      it "refuses a title containing a carriage return" do
        expect { described_class.new(id: "s1", title: "foo\r", size: "M") }
          .to raise_error(Lain::Plan::MalformedStep)
      end

      it "refuses a title with leading whitespace" do
        expect { described_class.new(id: "s1", title: "  indented", size: "M") }
          .to raise_error(Lain::Plan::MalformedStep, /whitespace/)
      end

      it "refuses a title with trailing whitespace" do
        expect { described_class.new(id: "s1", title: "foo ", size: "M") }
          .to raise_error(Lain::Plan::MalformedStep, /whitespace/)
      end

      it "refuses a title ending in a ` {...}` group (the criteria-digest collision)" do
        expect { described_class.new(id: "s1", title: "do thing {blake3:xyz}", size: "M") }
          .to raise_error(Lain::Plan::MalformedStep, /do thing \{blake3:xyz\}/)
      end

      it "refuses an id containing a backtick, naming the value and the delimiter" do
        expect { described_class.new(id: "a`b", title: "t", size: "M") }
          .to raise_error(Lain::Plan::MalformedStep, /a`b/)
      end

      it "refuses a criteria_digest containing a closing brace" do
        expect { described_class.new(id: "s1", title: "t", size: "M", criteria_digest: "a}b") }
          .to raise_error(Lain::Plan::MalformedStep, /a\}b/)
      end

      it "still accepts a normal brace-free title and round-trips it digest-identically" do
        doc = Lain::Plan::Document.new(steps: [described_class.new(id: "s1", title: "do the thing",
                                                                   size: "M", criteria_digest: "blake3:xyz")])

        expect(Lain::Plan::Document.parse_markdown(doc.to_markdown).digest).to eq(doc.digest)
      end
    end
  end

  describe "chunks and seams" do
    # Given a document with three steps and seams after each [internal boundary].
    subject(:seamed) { document.insert_seam(after: "s1").insert_seam(after: "s2") }

    it "splits into one chunk per step when every boundary is seamed" do
      expect(seamed.chunks.map { |chunk| chunk.map(&:id) }).to eq([["s1"], ["s2"], ["s3"]])
    end

    it "merges the adjacent chunks when a seam is removed, showing exactly one seam" do
      merged = seamed.remove_seam(after: "s2")

      expect(merged.chunks.map { |chunk| chunk.map(&:id) }).to eq([["s1"], %w[s2 s3]])
      expect(merged.to_markdown.scan("---").size).to eq(1)
    end

    it "is one chunk with no seams" do
      expect(document.chunks.map { |chunk| chunk.map(&:id) }).to eq([%w[s1 s2 s3]])
    end

    it "refuses a seam after a step that does not exist" do
      expect { document.insert_seam(after: "nope") }.to raise_error(Lain::Plan::UnknownStep)
    end

    it "refuses a seam after the last step (it bounds nothing)" do
      expect { document.insert_seam(after: "s3") }.to raise_error(ArgumentError, /last step/)
    end

    it "refuses to remove a seam that is not there" do
      expect { document.remove_seam(after: "s2") }.to raise_error(Lain::Plan::UnknownStep)
    end

    it "normalizes an equivalent seam set to one value regardless of build order" do
      a = document.insert_seam(after: "s2").insert_seam(after: "s1")
      b = document.insert_seam(after: "s1").insert_seam(after: "s2")

      expect(a).to eq(b)
      expect(a.digest).to eq(b.digest)
    end
  end

  describe "#advance" do
    it "returns a new document with only the named step's status changed" do
      advanced = document.advance("s2", status: "done")

      expect(document.steps.map(&:status)).to eq(%w[pending pending pending]) # original untouched
      expect(advanced.steps.map(&:status)).to eq(%w[pending done pending])
    end

    it "refuses to advance a step that does not exist" do
      expect { document.advance("nope", status: "done") }.to raise_error(Lain::Plan::UnknownStep)
    end
  end

  describe "immutability -- the sent-not-stored carrier never mutates" do
    it "is Ractor.shareable? (deeply frozen, no reachable mutable state)" do
      expect(document.insert_seam(after: "s1").advance("s1", status: "active")).to be_ractor_shareable
    end

    it "has Ractor.shareable? steps" do
      expect(document.steps).to all(be_ractor_shareable)
    end

    it "is value-equal to another document built from the same inputs" do
      expect(described_class.new(steps:)).to eq(described_class.new(steps:))
    end

    # N1: the constructor must not freeze the caller's array in place -- it copies
    # before freezing, so a caller can keep mutating its own steps array.
    it "leaves the caller's steps array unfrozen" do
      caller_steps = steps.dup
      described_class.new(steps: caller_steps)

      expect(caller_steps).not_to be_frozen
    end
  end

  describe "#digest -- content-addressed, Store-borne" do
    it "is a blake3 content address" do
      expect(document.digest).to start_with("blake3:")
    end

    it "changes when a step's status changes" do
      expect(document.advance("s1", status: "done").digest).not_to eq(document.digest)
    end

    it "survives a Store round-trip by digest (so it survives fork/replay)" do
      store = Lain::Store.new
      digest = store.put(document)

      expect(digest).to eq(document.digest)
      expect(store.fetch(digest)).to eq(document)
    end
  end

  describe "#to_reminder -- the Workspace projection" do
    subject(:reminder) { document.insert_seam(after: "s1").advance("s1", status: "active").to_reminder }

    it "names the chunks and each step's status" do
      expect(reminder).to include("Chunk 1", "Chunk 2")
      expect(reminder).to include("s1", "active")
      expect(reminder).to include("s3", "pending")
    end

    it "rides the Workspace as an ordinary tagged reminder block" do
      block = Lain::Workspace.empty.with(reminder).to_blocks.first

      expect(block["text"]).to include("Chunk 1")
    end
  end

  describe "#to_markdown -- the author-editable artifact that round-trips" do
    subject(:edited) { document.insert_seam(after: "s1").advance("s3", status: "done") }

    it "shows visible seams, sizes, statuses, and criteria references" do
      markdown = edited.to_markdown

      expect(markdown).to include("- [ ] `s1` (M) First step")
      expect(markdown).to include("- [ ] `s2` (S) Second step {blake3:abc123}")
      expect(markdown).to include("- [x] `s3` (L) Third step")
      expect(markdown).to include("\n---\n")
    end

    it "parses back to a value with the same digest -- the author-review loop" do
      parsed = described_class.parse_markdown(edited.to_markdown)

      expect(parsed).to eq(edited)
      expect(parsed.digest).to eq(edited.digest)
    end

    it "ignores prose and blank lines around the plan on the way back" do
      decorated = "Some intro.\n\n#{document.to_markdown}\n\nSome outro.\n"

      expect(described_class.parse_markdown(decorated).digest).to eq(document.digest)
    end
  end
end
