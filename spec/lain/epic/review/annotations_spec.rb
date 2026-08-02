# frozen_string_literal: true

RSpec.describe Lain::Epic::Review::Annotations do
  # Line 1 is the preamble, 3 and 6 are headings, 4 and 7 are the bodies under
  # them. Every example names lines from this map, so an off-by-one in the
  # attribution has somewhere to show itself.
  def document
    <<~MARKDOWN
      preamble

      ### [ ] `a1` First issue
      first body

      ### [ ] `b2` Second issue
      second body
    MARKDOWN
  end

  # The shape `spec/lain/frontend/neovim_runtime_spec.rb` pins from a REAL nvim:
  # an extmark crosses msgpack from lua, so its keys arrive as Strings. Every
  # production annotation looks like this and none looks like the Symbol-keyed
  # literal a Ruby spec reaches for by habit.
  def from_the_editor(line:, text:, anchor_text:)
    { "line" => line, "text" => text, "anchor_text" => anchor_text }
  end

  it "reads the String-keyed shape the editor hands across msgpack" do
    resolved = described_class.resolve([from_the_editor(line: 7, text: "tighten this AC",
                                                        anchor_text: "second body")], document)

    expect(resolved).to contain_exactly(
      { line: 7, text: "tighten this AC", anchor_text: "second body", issue_id: "b2", drifted: false }
    )
  end

  # An in-process caller writes Symbols, the wire delivers Strings, and both name
  # one note -- so the reader normalizes once rather than making every caller
  # remember which side it is on.
  it "reads a Symbol-keyed note from an in-process caller the same way" do
    resolved = described_class.resolve([{ line: 7, text: "tighten this AC", anchor_text: "second body" }], document)

    expect(resolved.first).to include(issue_id: "b2", drifted: false)
  end

  it "attributes a note on the heading line itself to that heading" do
    resolved = described_class.resolve([from_the_editor(line: 6, text: "retitle",
                                                        anchor_text: "### [ ] `b2` Second issue")], document)

    expect(resolved.first).to include(line: 6, issue_id: "b2", drifted: false)
  end

  it "does not guess an issue for preamble notes" do
    resolved = described_class.resolve([from_the_editor(line: 1, text: "intro", anchor_text: "preamble")], document)

    expect(resolved.first).to include(issue_id: nil, drifted: false)
  end

  # The journal is the only order a reader ever gets, so the order notes arrive
  # in is the order they are journaled in. Nothing else records which extmark
  # the human placed first.
  it "keeps the order the notes arrived in" do
    notes = [from_the_editor(line: 7, text: "second", anchor_text: "second body"),
             from_the_editor(line: 4, text: "first", anchor_text: "first body")]

    expect(described_class.resolve(notes, document).map { |note| note[:text] }).to eq(%w[second first])
  end

  # The drift case, which is what an extmark DOES when the human keeps editing:
  # the mark slides onto a neighbouring line and the text it was anchored to is
  # gone. The line number then names something the human never pointed at, so
  # attributing it to whatever heading now precedes it would be a guess dressed
  # as a reading.
  it "reports a note whose anchor line no longer says what it anchored as drifted" do
    resolved = described_class.resolve([from_the_editor(line: 7, text: "tighten this AC",
                                                        anchor_text: "a line the human deleted")], document)

    expect(resolved.first).to include(line: 7, anchor_text: "a line the human deleted",
                                      issue_id: nil, drifted: true)
  end

  it "reports a note past the end of the document as drifted rather than guessing the last heading" do
    resolved = described_class.resolve([from_the_editor(line: 99, text: "off the end", anchor_text: "gone")],
                                       document)

    expect(resolved.first).to include(issue_id: nil, drifted: true)
  end

  # Dropping it would lose the human's words, which are the part of a note that
  # cannot be reconstructed. The anchor text travels with it so a reader can find
  # where it meant by searching rather than by trusting the number.
  it "keeps a drifted note rather than dropping it" do
    notes = [from_the_editor(line: 4, text: "still here", anchor_text: "first body"),
             from_the_editor(line: 7, text: "drifted", anchor_text: "vanished")]

    resolved = described_class.resolve(notes, document)

    expect(resolved.map { |note| note[:text] }).to eq(["still here", "drifted"])
    expect(resolved.map { |note| note[:drifted] }).to eq([false, true])
  end

  # The line is a KEY into the document, so it is read exactly as strictly as a
  # generation is read off the same wire: `"7abc"` truncated to 7 and `7.9`
  # truncated to 7 both attribute a note to a line nobody named.
  it "refuses a line that is not a positive canonical integer, rather than truncating it" do
    ["7abc", 7.9, nil, 0, "", -1].each do |line|
      expect { described_class.resolve([from_the_editor(line:, text: "t", anchor_text: "second body")], document) }
        .to raise_error(ArgumentError, /line/)
    end
  end

  it "reads a canonical wire integer as the line it keys on" do
    resolved = described_class.resolve([from_the_editor(line: "7", text: "t", anchor_text: "second body")], document)

    expect(resolved.first).to include(line: 7, issue_id: "b2")
  end
end
