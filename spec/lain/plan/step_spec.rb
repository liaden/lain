# frozen_string_literal: true

# Step's own mirror. Its examples lived nested inside plan_spec.rb (soon
# spec/lain/plan/document_spec.rb) because Document's spec needed steps to
# build one anyway; the markdown identifier grammar Step shares with
# Epic::Issue and Question (spec/lain/markdown_identifier_spec.rb) is why it
# earns a subject and a mirror path of its own.
RSpec.describe Lain::Plan::Step do
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

  # The markdown round-trip must be total -- every constructible Step must
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

    # The shared markdown-identifier rule (lib/lain/markdown_identifier.rb):
    # the same grammar phrase Epic::Issue and Question refuse a backtick
    # under, pinned here so the three cannot drift apart silently -- the
    # cross-consumer property itself lives in markdown_identifier_spec.rb.
    it "names the shared backtick grammar, not a Step-only phrase" do
      expect { described_class.new(id: "a`b", title: "t", size: "M") }
        .to raise_error(Lain::Plan::MalformedStep) { |error|
          expect(error.message).to include(Lain::MarkdownIdentifier::BACKTICK_GRAMMAR)
        }
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
