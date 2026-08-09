# frozen_string_literal: true

# Which chunker a path gets. The dispatch is one method and its whole job is a
# routing decision, so the examples below assert the ROUTE -- the object handed
# back -- rather than re-testing what each chunker does with a file; every one
# of those has its own spec and the shared coverage contract besides.
RSpec.describe Lain::Survey::Chunker do
  describe ".for" do
    it "sends markdown to the section chunker, which is the one that reads its structure" do
      expect(described_class.for("docs/guide.md")).to be_a(described_class::Markdown)
    end

    it "routes every spelling of markdown it claims, since a README picks one arbitrarily" do
      routed = described_class::MARKDOWN.to_h { |ext| [ext, described_class.for("readme#{ext}")] }

      expect(routed.values).to all(be_a(described_class::Markdown))
      expect(described_class::MARKDOWN).to include(".md")
    end

    it "sends a language lain can parse to the definition chunker" do
      expect(described_class.for("lib/lain/review/hunk.rb")).to be_a(described_class::Code)
    end

    it "routes every extension the code table names, so a language is not reachable by luck" do
      routed = described_class::Code::EXTENSIONS.keys.to_h { |ext| [ext, described_class.for("a#{ext}")] }

      expect(routed.values).to all(be_a(described_class::Code))
    end

    # The floor is the answer to everything unrecognised, and that is the
    # dispatch's whole posture: a survey that cannot read a `.lua` file at all
    # is worse than one that reads it as prose.
    it "sends an unrecognised extension to the paragraph floor rather than refusing" do
      expect(described_class.for("var/log/build.log")).to be_a(described_class::Paragraphs)
    end

    it "sends a file with no extension at all to the floor" do
      expect(described_class.for("Makefile")).to be_a(described_class::Paragraphs)
    end

    # `Structural::Queries` is the one classifier, and the dispatch asks it
    # rather than trusting the extension table -- so a language whose authored
    # query is withdrawn falls to the floor here instead of reaching a chunker
    # that would fall to the floor internally and report nothing about why.
    it "asks the query table, so a language with no symbols query is not sent to the code chunker" do
      allow(Lain::Structural::Queries).to receive(:languages_for).with(:symbols).and_return([])

      expect(described_class.for("lib/thing.rb")).to be_a(described_class::Paragraphs)
    end

    # A chunker is a frozen `Data` precisely so that two derivations of one
    # corpus compare equal -- {Lain::Review::LazyFile}'s equality runs through
    # whatever chunks it, and a callable that compares unequal after a rebuild
    # raises a `KeyError` a long way from its cause.
    it "answers equal chunkers for one path, so two derivations of a corpus compare equal" do
      expect(described_class.for("notes.md")).to eq(described_class.for("notes.md"))
      expect(described_class.for("a.rb")).to eq(described_class.for("b.rb"))
    end

    it "answers a frozen value, since a chunker is configuration and not state" do
      expect(described_class.for("notes.md")).to be_frozen
    end
  end
end
