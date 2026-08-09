# frozen_string_literal: true

# The COVERAGE CONTRACT every survey chunker is held to. A chunker turns a file
# into {Lain::Survey::Unit}s, and the one law that makes marking a file honest is
# that the units ARE the file: ordered, and every line in exactly one of them.
#
# It is stated as a RECONSTRUCTION, never as a line count, because a count is
# satisfied by units that duplicate one line and drop another. Concatenating the
# units in order and comparing bytes catches gaps, duplication and reordering
# with one assertion -- and it is byte-for-byte, so a CRLF file's carriage
# returns are content the contract protects rather than line endings a chunker
# may normalize away.
#
# The contract is deliberately TYPE-AGNOSTIC. Nothing here may mention markdown,
# a heading, a language or a syntax tree: the paragraph floor, the markdown
# section tree and the code partition all pass this group unchanged, which is
# what makes "a line in no unit is never shown" a property of the survey rather
# than of whichever chunker happened to run.
#
# Include with a Hash:
#
#   chunker [#call -> chunker]  a fresh chunker, called once per example.
#   corpus  [Hash]              description => {path:, source:}, the files the
#                               contract is checked over. A chunker owes at
#                               least one file of its OWN kind here; the empty
#                               file and the trailing-newline-less file are
#                               added by the group itself, since every chunker
#                               must survive them.
#
# The callable runs through #chunker_call for the same reason "a review
# changeset source" does (see review_source.rb): the config Hash is built in a
# `describe` body, so a Proc literal there closes over the example GROUP, and
# `instance_exec` rebinds it to the real example so fixture helpers resolve.
RSpec.shared_examples "a survey chunker" do |config|
  chunker = config.fetch(:chunker)
  corpus = config.fetch(:corpus)

  define_method(:chunker_call) { |callable, *args| instance_exec(*args, &callable) }

  subject(:survey_chunker) { chunker_call(chunker) }

  # The file rebuilt from its units. The trailing newline is the file's own
  # property, not a unit's -- lines are terminator-free by {Unit.lines_of}'s
  # rule -- so it is restored here rather than carried by the last unit.
  def reconstructed(units, source)
    body = units.flat_map(&:lines).join("\n")
    source.end_with?("\n") ? "#{body}\n" : body
  end

  corpus.each do |description, file|
    context "with #{description}" do
      let(:units) { survey_chunker.call(path: file.fetch(:path), source: file.fetch(:source)) }

      it "reconstructs the file byte for byte" do
        expect(reconstructed(units, file.fetch(:source))).to eq(file.fetch(:source))
      end

      # The one law reconstruction cannot state, and the gap a real defect hid
      # in: the trailing newline is restored from the SOURCE, so a chunker
      # emitting NO units for a file of one newline "reconstructed" it
      # perfectly while showing a reviewer nothing.
      it "produces no units only for a file with no bytes" do
        expect(units.empty?).to eq(file.fetch(:source).empty?)
      end

      it "claims every line of the file, in the file's own order" do
        expect(units.flat_map(&:lines)).to eq(Lain::Survey::Unit.lines_of(file.fetch(:source)))
      end

      # Contiguity is what turns "the lines concatenate" into "the units are
      # POSITIONED where they say they are" -- a chunker could reconstruct the
      # file perfectly while numbering every unit from line 1.
      it "numbers the units contiguously from the first line" do
        expected = units.inject([1]) { |starts, unit| starts << (starts.last + unit.lines.size) }
        expect(units.map(&:start_line)).to eq(expected.first(units.size))
      end

      it "carries the path it was given into every unit" do
        expect(units.map(&:path).uniq).to eq(units.empty? ? [] : [file.fetch(:path)])
      end

      # An empty unit is invisible to a reviewer and still consumes a mark, so
      # it is the one shape the reconstruction law cannot see.
      it "emits no empty unit" do
        expect(units.map { |unit| unit.lines.size }).to all(be_positive)
      end

      it "gives each unit a distinct key" do
        keys = Lain::Survey::Unit.keys(units)
        expect(keys.uniq.size).to eq(units.size)
      end

      it "produces deeply frozen, Ractor-shareable units" do
        expect(units).to all(satisfy { |unit| Ractor.shareable?(unit) })
      end
    end
  end

  context "with an empty file" do
    it "produces no units at all" do
      expect(survey_chunker.call(path: "empty.txt", source: "")).to eq([])
    end
  end

  context "with a file whose last line carries no newline" do
    let(:source) { "alpha\nbeta" }

    it "does not invent a terminator" do
      units = survey_chunker.call(path: "unterminated.txt", source:)
      expect(reconstructed(units, source)).to eq(source)
    end
  end

  # Every chunker gets these three whatever its corpus says, because each one
  # was a live defect in one chunker and a pass in the others.
  context "with a file holding one newline and nothing else" do
    it "shows the empty line it holds" do
      units = survey_chunker.call(path: "one-newline.md", source: "\n")

      expect(units.flat_map(&:lines)).to eq([""])
      expect(reconstructed(units, "\n")).to eq("\n")
    end
  end

  context "with a file whose bytes are not valid UTF-8" do
    let(:source) { "alpha\n caf\xE9 \nbeta\n" }

    it "chunks it rather than raising out of String#split" do
      units = survey_chunker.call(path: "latin1.md", source:)

      expect(reconstructed(units, source)).to eq(source)
      expect(units).not_to be_empty
    end
  end

  context "with a file that is one line of many bytes and no structure" do
    let(:source) { "#{"emoji 🙂 and é " * 40}\n" }

    it "keeps the multi-byte characters whole" do
      expect(reconstructed(survey_chunker.call(path: "wide.md", source:), source)).to eq(source)
    end
  end
end
