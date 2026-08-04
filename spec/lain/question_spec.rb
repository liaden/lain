# frozen_string_literal: true

RSpec.describe Lain::Question do
  subject(:question) { described_class.new(id: "deploy", body: markdown, options: [yes, no]) }

  let(:markdown) { "Ship it?\n\n```ruby\nputs :hi\n```\n" }
  let(:yes) { Lain::Question::Option.new(id: "yes", label: "Ship now") }
  let(:no) { Lain::Question::Option.new(id: "no", label: "Hold") }

  describe "construction" do
    it "is deeply frozen and Ractor-shareable, options and all" do
      expect(question).to be_deeply_frozen
      expect(question.options).to be_deeply_frozen
    end

    it "defaults to single-select and carries its options in order" do
      expect(question).to be_single
      expect(question).not_to be_multi
      expect(question.options.map(&:id)).to eq(%w[yes no])
      expect(question.options.map(&:label)).to eq(["Ship now", "Hold"])
    end

    it "is free text exactly when it has no options" do
      expect(described_class.new(id: "why", body: "Why?")).to be_free_text
      expect(question).not_to be_free_text
    end

    it "preserves a markdown body verbatim, fences included" do
      expect(question.body).to eq(markdown)
    end

    it "preserves a CRLF body verbatim, so a line splitter downstream sees what was written" do
      expect(described_class.new(id: "why", body: "a\r\nb").body).to eq("a\r\nb")
    end
  end

  describe "arity" do
    it "carries multi-select as first-class data" do
      multi = described_class.new(id: "who", body: "Who?", arity: "multi", options: [yes])
      expect(multi).to be_multi
      expect(multi).not_to be_single
    end

    it "takes a Symbol arity as the same message, frozen and interned" do
      expect(described_class.new(id: "who", body: "Who?", arity: :multi)).to be_multi
    end

    it "refuses an arity outside the closed set, naming the legal ones" do
      expect { described_class.new(id: "who", body: "Who?", arity: "some") }
        .to raise_error(ArgumentError, /arity.*single.*multi/m)
    end
  end

  describe "validation" do
    it "refuses two options sharing an id, naming the duplicate" do
      expect do
        described_class.new(id: "deploy", body: "Ship it?",
                            options: [yes, Lain::Question::Option.new(id: "yes", label: "Ship later")])
      end.to raise_error(ArgumentError, /yes/)
    end

    it "refuses a blank id and a blank body" do
      expect { described_class.new(id: " ", body: "Ship it?") }.to raise_error(ArgumentError, /id/)
      expect { described_class.new(id: "deploy", body: "") }.to raise_error(ArgumentError, /body/)
    end

    it "refuses an id carrying a character the document grammar reserves, naming WHICH grammar" do
      expect { described_class.new(id: "de`ploy", body: "Ship it?") }.to raise_error(ArgumentError, /code span/)
      expect { described_class.new(id: "de\nploy", body: "Ship it?") }.to raise_error(ArgumentError, /heading/)
    end

    # A zero-width character is not [[:space:]] to any locale, so ID_PADDED cannot
    # see it and `presence` counts it as present: "ab" and "a​b" would be two
    # ids one human reads as one. Refused for the same reason NOTHING_AT_ALL exists.
    it "refuses an id carrying a character no human can see" do
      expect { described_class.new(id: "a​b", body: "Ship it?") }.to raise_error(ArgumentError, /see/)
      expect { described_class.new(id: "​", body: "Ship it?") }.to raise_error(ArgumentError, /see/)
      expect { described_class.new(id: "a﻿b", body: "Ship it?") }.to raise_error(ArgumentError, /see/)
    end

    it "refuses an option label that is not one line" do
      expect { Lain::Question::Option.new(id: "yes", label: "one\ntwo") }.to raise_error(ArgumentError, /label/)
    end

    it "refuses an options list that is not an Array" do
      expect { described_class.new(id: "deploy", body: "Ship it?", options: "yes") }
        .to raise_error(ArgumentError, /Array/)
    end

    it "refuses a body that is not text, rather than inspecting it into one" do
      expect { described_class.new(id: "deploy", body: %w[one two]) }.to raise_error(ArgumentError, /Array/)
      expect { described_class.new(id: "deploy", body: { "a" => 1 }) }.to raise_error(ArgumentError, /Hash/)
      expect { described_class.new(id: 42, body: "Ship it?") }.to raise_error(ArgumentError, /Integer/)
    end

    it "refuses a body that is not valid UTF-8, the way Canonical would" do
      expect { described_class.new(id: "deploy", body: (+"\xff\xfe").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /UTF-8/)
    end
  end

  # S2: a code span strips one leading and one trailing space from its content,
  # so a padded id renders as text a parser reads back as a DIFFERENT id -- and
  # `distinct!` never sees the collision, because it compares pre-render bytes.
  describe "id hygiene" do
    it "refuses an id padded with whitespace rather than silently stripping it" do
      expect { described_class.new(id: " deploy ", body: "Ship it?") }.to raise_error(ArgumentError, /whitespace/)
      expect { described_class.new(id: "deploy ", body: "Ship it?") }.to raise_error(ArgumentError, /whitespace/)
    end

    it "refuses a padded option id too, since both are join keys" do
      expect { Lain::Question::Option.new(id: "yes ", label: "Ship now") }.to raise_error(ArgumentError, /whitespace/)
    end

    it "keeps an id with an interior space, which a code span preserves" do
      expect(described_class.new(id: "ship now", body: "Ship it?").id).to eq("ship now")
    end
  end

  # S1: MAX_BODY bounded one field out of five. Every free field is bounded now,
  # and the SET bounds the serialized whole (see the set spec).
  describe "size bounds" do
    it "refuses a body beyond the documented maximum, naming the size, rather than truncating" do
      oversized = "x" * (described_class::MAX_BODY + 1)
      expect { described_class.new(id: "big", body: oversized) }
        .to raise_error(ArgumentError, /#{oversized.bytesize}.*#{described_class::MAX_BODY}/)
    end

    it "accepts a body exactly at the maximum, counted in bytes" do
      expect(described_class.new(id: "big", body: "x" * described_class::MAX_BODY).body.bytesize)
        .to eq(described_class::MAX_BODY)
    end

    it "refuses an id beyond its own maximum" do
      oversized = "x" * (described_class::MAX_ID + 1)
      expect { described_class.new(id: oversized, body: "Ship it?") }
        .to raise_error(ArgumentError, /#{oversized.bytesize}.*#{described_class::MAX_ID}/)
    end

    it "refuses an option id and an option label beyond their maximums" do
      max_id = described_class::MAX_ID
      max_label = described_class::MAX_LABEL
      expect { Lain::Question::Option.new(id: "x" * (max_id + 1), label: "Ship now") }
        .to raise_error(ArgumentError, /#{max_id}/)
      expect { Lain::Question::Option.new(id: "yes", label: "x" * (max_label + 1)) }
        .to raise_error(ArgumentError, /#{max_label}/)
    end
  end

  # B1: an unclosed fence does not break the PARSER (it matches the body region
  # literally and skips it whole), but it wrecks the DOCUMENT -- every option
  # checkbox below an unclosed fence renders as code in the buffer the human
  # answers in. The rule is CommonMark's, not "count the ``` lines".
  describe "fence balance" do
    def body_for(text) = described_class.new(id: "q", body: text)

    it "accepts a balanced backtick fence, a tilde fence, and a mermaid block" do
      expect(body_for("```ruby\nputs 1\n```\n").body).to include("puts 1")
      expect(body_for("~~~\nplain\n~~~\n").body).to include("plain")
      expect(body_for("```mermaid\ngraph TD;\nA-->B;\n```\n").body).to include("graph TD;")
    end

    it "accepts a longer fence holding a shorter one, which is why counting markers is wrong" do
      expect(body_for("````\n```\nnot a fence\n```\n````\n").body).to include("not a fence")
    end

    it "accepts a fence closed by a LONGER run of the same character" do
      expect(body_for("```\nx\n`````\n").body).to include("x")
    end

    it "accepts a fence indented up to three spaces, as CommonMark allows" do
      expect(body_for("   ```\nx\n   ```\n").body).to include("x")
    end

    it "does not read a code span as a fence opener, because an info string holds no backtick" do
      expect(body_for("```x``` is a span, not a fence\n").body).to include("span")
    end

    it "refuses an unclosed fence, naming the fence and its line" do
      expect { body_for("Ship it?\n\n```ruby\nputs 1\n") }.to raise_error(ArgumentError, /```.*line 3/)
    end

    it "refuses a backtick fence a tilde run does not close" do
      expect { body_for("```\nx\n~~~\n") }.to raise_error(ArgumentError, /never closes/)
    end

    it "refuses a fence whose closer is shorter than its opener" do
      expect { body_for("````\nx\n```\n") }.to raise_error(ArgumentError, /never closes/)
    end

    it "refuses a fence whose closer carries an info string, which cannot close" do
      expect { body_for("```\nx\n``` ruby\n") }.to raise_error(ArgumentError, /never closes/)
    end
  end

  # T5/B1: a label is rendered at the END of an option line in the answer
  # document, and that document's parse strips every line it reads -- so a label
  # that does not survive an `rstrip` is one the renderer writes and the parser
  # then refuses, blaming the human for a line they never touched and leaving
  # the question permanently unanswerable. The rule is stated as the rstrip
  # itself rather than as a whitespace class, because `String#rstrip` is
  # ASCII-only: a label ending in U+00A0 round-trips untouched and is not this
  # defect.
  describe "a label the answer document could not read back" do
    it "refuses a label ending in a space, naming it rather than trimming it" do
      expect { Lain::Question::Option.new(id: "yes", label: "Ship now ") }
        .to raise_error(ArgumentError, /"Ship now ".*refused rather than trimmed/m)
    end

    it "refuses a label ending in a tab" do
      expect { Lain::Question::Option.new(id: "yes", label: "Ship now\t") }
        .to raise_error(ArgumentError, /ends in whitespace/)
    end

    it "accepts a label ending in whitespace an rstrip does not eat, since it survives the round trip" do
      # Written as an escape on purpose: the offending byte is invisible otherwise, which is
      # the same trap S3 names in the mark refusal.
      label = "Ship now\u00A0"

      expect(Lain::Question::Option.new(id: "yes", label:).label).to end_with("\u00A0")
    end

    it "accepts a label that BEGINS with whitespace, which the document renders and reads back whole" do
      expect(Lain::Question::Option.new(id: "yes", label: " Ship now").label).to eq(" Ship now")
    end
  end

  # T5: the answer document finds a question by its heading, and so does the `x`
  # keymap above it -- by scanning UP from an option line to the nearest one,
  # out of buffer text alone, with no RPC and no fence state. A body line
  # wearing that exact shape would put every option below it under the wrong
  # question. Refused HERE rather than at render, because a question that exists
  # but cannot be displayed is worse than a refused tool call: the model gets a
  # named refusal and retries, where the human would get an inbox item that will
  # not open and no way out of it from the editor.
  describe "a body that forges the answer document's heading" do
    def body_for(text) = described_class.new(id: "q", body: text)

    it "refuses a line matching a heading the document would write, naming the line" do
      expect { body_for("Pick one:\n\n## `other` (choose one)\n") }
        .to raise_error(ArgumentError, /"## `other` \(choose one\)".*question heading/m)
    end

    it "refuses one for every kind of question the document can write" do
      Lain::Question::Document::KIND_LABELS.each_value do |label|
        expect { body_for("## `other` (#{label})") }.to raise_error(ArgumentError, /question heading/)
      end
    end

    it "refuses one inside a fence, because the editor's scan does not track fences either" do
      expect { body_for("```\n## `other` (choose one)\n```\n") }.to raise_error(ArgumentError, /question heading/)
    end

    it "refuses one whose line ends in a CR, which the document's parse strips before it matches" do
      expect { body_for("## `other` (choose one)\r\n") }.to raise_error(ArgumentError, /question heading/)
    end

    it "leaves an ordinary markdown heading alone" do
      expect(body_for("## Overview\n\nWhich one?\n").body).to include("## Overview")
    end

    it "leaves a heading-shaped line carrying no backticked id alone" do
      expect(body_for("## other (choose one)\n").body).to include("choose one")
    end

    it "leaves a deeper heading alone, since the document writes only two hashes" do
      expect(body_for("### `other` (choose one)\n").body).to include("choose one")
    end
  end

  # S3: one member policy for both lists in this unit. A member arrives BUILT;
  # `from_body` is the documented way in from raw data.
  describe "member policy" do
    it "refuses a raw option Hash, naming the class and the way in" do
      expect { described_class.new(id: "deploy", body: "Ship it?", options: [{ "id" => "yes", "label" => "Y" }]) }
        .to raise_error(ArgumentError, /Option.*from_body/m)
    end

    it "builds those same hashes through from_body" do
      built = described_class.from_body("id" => "deploy", "body" => "Ship it?",
                                        "options" => [{ "id" => "yes", "label" => "Ship now" }])
      expect(built.options).to eq([yes])
    end
  end

  describe "the body hash" do
    it "round-trips through a plain Hash" do
      expect(described_class.from_body(question.to_body)).to eq(question)
    end

    it "round-trips a free-text question" do
      free = described_class.new(id: "why", body: "Why?")
      expect(described_class.from_body(free.to_body)).to eq(free)
    end

    it "names every field, so the shape is stable across questions" do
      expect(question.to_body).to eq(
        "id" => "deploy",
        "body" => markdown,
        "arity" => "single",
        "options" => [{ "id" => "yes", "label" => "Ship now" },
                      { "id" => "no", "label" => "Hold" }]
      )
    end

    it "reads a Symbol-keyed hash the way Canonical does, as the same message" do
      expect(described_class.from_body(id: "why", body: "Why?", arity: "single", options: []))
        .to eq(described_class.new(id: "why", body: "Why?"))
    end

    # S5: Canonical RAISES on a Hash holding both :a and "a". Reading one of them
    # silently builds a question that cannot be content-addressed a moment later.
    it "refuses a key held as both a String and a Symbol, the way Canonical does" do
      expect { described_class.from_body({ :id => "sym", "id" => "str", "body" => "Why?" }) }
        .to raise_error(ArgumentError, /both a String and a Symbol/)
    end

    it "refuses a body that is not a Hash, naming it" do
      expect { described_class.from_body("nope") }.to raise_error(ArgumentError, /Hash/)
    end

    it "names the field a malformed body is missing, and the object being built" do
      expect { described_class.from_body("id" => "why") }.to raise_error(ArgumentError, /a question body.*"body"/)
    end
  end

  describe Lain::Question::Option do
    subject(:option) { described_class.new(id: "yes", label: "Ship now") }

    it "is deeply frozen" do
      expect(option).to be_deeply_frozen
    end

    it "round-trips through a plain Hash" do
      expect(described_class.from_body(option.to_body)).to eq(option)
    end

    it "refuses a blank id and a blank label" do
      expect { described_class.new(id: "", label: "Ship now") }.to raise_error(ArgumentError, /id/)
      expect { described_class.new(id: "yes", label: " ") }.to raise_error(ArgumentError, /label/)
    end

    it "names the field a malformed body is missing" do
      expect { described_class.from_body("id" => "yes") }.to raise_error(ArgumentError, /an option body.*"label"/)
    end
  end
end
