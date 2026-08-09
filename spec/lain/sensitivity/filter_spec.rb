# frozen_string_literal: true

# The classifier's answer applied to a LIST rather than to one path, which is a
# different question with a different shape: not "may this read happen" but
# "which of these rows may the model see, and how many did I take away".
#
# Every example drives the REAL {Lain::Sensitivity}. A doubled classifier would
# let this file agree with itself about what `.env` is, and the rows here are
# exactly the paths whose verdicts the tables decide.
RSpec.describe Lain::Sensitivity::Filter do
  subject(:filter) { described_class.new(sensitivity:) }

  let(:home) { "/home/tester" }
  # `cwd:` is required and has no `Dir.pwd` default (the chunk's ruling), so it
  # is supplied here as it is at every other call site.
  let(:sensitivity) { Lain::Sensitivity.new(home:, cwd: "/proj") }

  # The readings a row has are the CALLER's to decide -- a glob row is a path
  # and a grep row is a path with a line number glued to it -- so the default
  # here is the simplest one and every example that cares supplies its own.
  def sift(rows, &readings)
    reader = readings || ->(row) { [row] }
    filter.sift(rows, &reader)
  end

  describe "what it keeps" do
    it "keeps every row whose readings are all ordinary" do
      rows = ["/proj/app.rb", "/proj/lib/context.rb"]

      sifted = sift(rows)

      expect(sifted.kept).to eq(rows)
      expect(sifted.withheld).to be_empty
      expect(sifted).not_to be_any
    end

    # grep's own `... capped at 200 matches` trailer is the row this exists
    # for: it names no path, so there is nothing to classify and nothing to
    # withhold. It is the one fail-OPEN case here, and it is safe only because
    # the caller's reader returns no reading rather than a wrong one.
    it "keeps a row that names no path at all" do
      sifted = sift(["... capped at 200 matches"]) { [] }

      expect(sifted.kept).to eq(["... capped at 200 matches"])
      expect(sifted.withheld).to be_empty
    end
  end

  describe "what it withholds" do
    it "withholds a gated path and carries the verdict that took it" do
      sifted = sift(["/proj/.env"])

      expect(sifted.kept).to be_empty
      expect(sifted.count).to eq(1)
      expect(sifted.reasons).to eq(%i[credential])
    end

    it "withholds a denied path" do
      sifted = sift(["#{home}/.ssh/id_rsa"])

      expect(sifted.kept).to be_empty
      expect(sifted.reasons).to eq(%i[protected])
    end

    # The ambiguity rule, and the whole reason a row has READINGS rather than a
    # path: `weird:1/.env:2:hit` has no unambiguous split, so every reading it
    # could have is judged and any sensitive one takes the row. A filter that
    # judged the first reading only would print the line out of the `.env`.
    it "withholds a row when ANY of its readings is sensitive" do
      sifted = sift(["ambiguous"]) { ["/proj/ok.rb", "/proj/.env"] }

      expect(sifted.kept).to be_empty
      expect(sifted.reasons).to eq(%i[credential])
    end

    it "counts a withheld row once however many readings it had" do
      sifted = sift(["ambiguous"]) { ["/proj/.env", "#{home}/.ssh/id_rsa"] }

      expect(sifted.count).to eq(1)
    end

    # {Lain::Sensitivity::MALFORMED} is GATED, not ordinary, so a row this
    # classifier cannot read is withheld rather than waved through. Fail-closed
    # is the only available direction: a path nobody can parse is a path nobody
    # can vouch for.
    it "withholds a row whose path cannot be read lexically" do
      sifted = sift(["/proj/a\0b"])

      expect(sifted.kept).to be_empty
      expect(sifted.reasons).to eq(%i[malformed])
    end
  end

  describe "what it reports" do
    it "names each distinct reason once, in a stable order" do
      sifted = sift(["/proj/.env", "#{home}/.ssh/id_rsa", "/proj/.netrc", "/proj/config/.env.local"])

      expect(sifted.count).to eq(4)
      expect(sifted.reasons).to eq(%i[credential protected])
    end

    # The count is the whole disclosure. Naming the paths would hand back what
    # the withholding took away, one indirection out.
    it "carries no path anywhere in what a caller reports" do
      sifted = sift(["/proj/.env"])

      expect(sifted.reasons.join).not_to include(".env")
      expect(sifted.count).to eq(1)
    end
  end

  describe "the Null" do
    subject(:filter) { described_class::Null.instance }

    it "keeps every row, so a run that wired no classifier filters nothing" do
      rows = ["/proj/.env", "#{home}/.ssh/id_rsa"]

      sifted = sift(rows)

      expect(sifted.kept).to eq(rows)
      expect(sifted.withheld).to be_empty
    end

    # A fresh Null per default would make two otherwise identical guards
    # compare unequal -- {Lain::Sensitivity::Policy::Null}'s reason.
    it "is one shared frozen instance" do
      expect(described_class::Null.instance).to equal(described_class::Null.instance)
      expect(described_class::Null.instance).to be_frozen
    end
  end

  # A nil classifier is what a half-finished wiring hands over, and a filter
  # that answered "nothing sensitive here" to it would be a withholding control
  # that withholds nothing, wearing this codebase's Null idiom as camouflage.
  it "refuses to be built without a classifier" do
    expect { described_class.new(sensitivity: nil) }.to raise_error(ArgumentError, /classifier/)
  end
end
