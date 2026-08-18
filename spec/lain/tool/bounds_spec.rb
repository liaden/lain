# frozen_string_literal: true

RSpec.describe Lain::Tool::Bounds do
  describe Lain::Tool::Bounds::Enumeration do
    subject(:bound) { described_class.new(limit: 200, unit: "matches") }

    let(:rows) { Array.new(10) { |i| "row #{i}" } }

    # Scenario: an enumeration within the cap is untouched
    it "returns the identical rows with no added text when the offer is within the cap" do
      expect(bound.cap(rows)).to eq(rows)
    end

    it "adds no notice to a within-cap enumeration" do
      expect(bound.cap(rows).join("\n")).not_to include("capped")
    end

    it "admits a count at exactly the cap" do
      expect(bound.admits?(200)).to be(true)
    end

    # Scenario: an enumeration over the cap is capped and says so in band
    it "returns exactly the cap's worth of rows when the offer is over" do
      capped = bound.cap(Array.new(5000) { |i| "row #{i}" })

      expect(capped.first(200)).to eq(Array.new(200) { |i| "row #{i}" })
    end

    it "follows the capped rows with a notice stating the cap and the true count" do
      capped = bound.cap(Array.new(5000) { |i| "row #{i}" })

      expect(capped.last).to eq("... capped at 200 of 5000 matches")
    end

    it "adds exactly one row of disclosure" do
      expect(bound.cap(Array.new(5000) { "row" }).size).to eq(201)
    end

    it "refuses a count over the cap" do
      expect(bound.admits?(201)).to be(false)
    end

    it "names the unit it was built with" do
      entries = described_class.new(limit: 2, unit: "entries")

      expect(entries.cap(%w[a b c]).last).to eq("... capped at 2 of 3 entries")
    end

    it "is a deeply frozen value object" do
      expect(Ractor.shareable?(bound)).to be(true)
    end

    # Every other example hands in a frozen literal, where `#to_s` returns self
    # and a dropped `String#-@` is invisible. A Symbol is the shape that makes
    # the deduplication load-bearing: `Symbol#to_s` hands back a MUTABLE String,
    # which is the exact trap CLAUDE.md records breaking deep immutability once.
    it "stays shareable when its unit arrives as a Symbol" do
      expect(Ractor.shareable?(described_class.new(limit: 1, unit: :entries))).to be(true)
    end

    it "stays shareable when its unit arrives interpolated" do
      width = 2

      expect(Ractor.shareable?(described_class.new(limit: 1, unit: "#{width}-grams"))).to be(true)
    end

    it "returns a frozen Array whether or not it capped" do
      expect([bound.cap(rows), bound.cap(Array.new(5000) { "row" })]).to all(be_frozen)
    end

    it "does not hand back the caller's own Array" do
      expect(bound.cap(rows)).not_to be(rows)
    end
  end

  describe Lain::Tool::Bounds::Artifact do
    subject(:bound) { described_class.new(limit: 262_144) }

    let(:narrower) { ["read a window with offset and limit", "run code_outline"] }

    # Scenario: an artifact over the cap is refused, naming a narrower action
    it "is an error Result" do
      refusal = bound.refusal(subject: "big.rb", size: 5_242_880, narrower:)

      expect(refusal).to be_a(Lain::Tool::Result).and be_error
    end

    it "states the actual size" do
      refusal = bound.refusal(subject: "big.rb", size: 5_242_880, narrower:)

      expect(refusal.content).to include("5242880")
    end

    it "states the cap" do
      refusal = bound.refusal(subject: "big.rb", size: 5_242_880, narrower:)

      expect(refusal.content).to include("262144")
    end

    it "names the subject that was refused" do
      refusal = bound.refusal(subject: "big.rb", size: 5_242_880, narrower:)

      expect(refusal.content).to include("big.rb")
    end

    it "names at least one narrower action" do
      refusal = bound.refusal(subject: "big.rb", size: 5_242_880, narrower:)

      expect(refusal.content).to include("read a window with offset and limit")
    end

    it "names every narrower action the caller supplied" do
      refusal = bound.refusal(subject: "big.rb", size: 5_242_880, narrower:)

      expect(refusal.content).to include("run code_outline")
    end

    # A refusal with nothing to fall back to is advice that sends the model
    # nowhere, which is the failure the doctrine's second half exists to avoid.
    it "refuses loudly to compose a refusal with no narrower action" do
      expect { bound.refusal(subject: "big.rb", size: 5_242_880, narrower: []) }
        .to raise_error(ArgumentError, /narrower/)
    end

    # Scenario: an artifact refusal carries none of the oversized content
    it "carries no bytes of the artifact in its message" do
      content = "SECRETPAYLOAD" * 5_000
      refusal = bound.refusal(subject: "big.rb", size: content.bytesize, narrower:)

      expect(refusal.content).not_to include("SECRETPAYLOAD")
    end

    # The mechanical statement of the same thing: content cannot appear in a
    # message that was never handed any. A parameter list is what a future edit
    # would have to change to break it, so that is what is pinned.
    it "cannot see the content, because no refusal parameter carries it" do
      expect(described_class.instance_method(:refusal).parameters.map(&:last))
        .to contain_exactly(:subject, :size, :narrower)
    end

    # #message is equally public and is what a caller that is not a tool reaches
    # for, so pinning #refusal alone leaves the sentence itself unguarded: a
    # `preview:` added HERE reaches the model through both methods.
    it "cannot see the content through the message either" do
      expect(described_class.instance_method(:message).parameters.map(&:last))
        .to contain_exactly(:subject, :size, :narrower)
    end

    # `size:` is declared an Integer and the decide-from-a-size-alone contract
    # rests on it, so the REFUSAL path has to be as loud about it as #admits? is.
    # `size: output` instead of `size: output.bytesize` is one character away in
    # a tool that holds both, and it would interpolate the whole payload into
    # the one message that exists to carry none of it.
    it "refuses a size that is not a byte count" do
      expect { bound.message(subject: "big.rb", size: "SECRETPAYLOAD" * 5_000, narrower:) }
        .to raise_error(ArgumentError, /String/)
    end

    it "refuses a nil size, naming the class rather than failing obscurely" do
      expect { bound.message(subject: "big.rb", size: nil, narrower:) }
        .to raise_error(ArgumentError, /NilClass/)
    end

    # The raise is not the end of the story: Effect::Handler::Live turns a
    # raising tool into `Result.error("#{e.class}: #{e.message}")`, so an
    # exception that echoes its argument reaches the model anyway -- one hop
    # further than the refusal, and just as leaked.
    it "names no byte of the payload in the exception either" do
      payload = "SECRETPAYLOAD" * 5_000
      raised = begin
        bound.refusal(subject: "big.rb", size: payload, narrower:)
      rescue ArgumentError => e
        e
      end

      expect("#{raised.class}: #{raised.message}").not_to include("SECRETPAYLOAD")
    end

    # Scenario: the refusal decision can be made from a size alone
    it "decides from a byte count and a bound, with no content present" do
      expect(bound.admits?(262_145)).to be(false)
    end

    it "admits a size at exactly the bound" do
      expect(bound.admits?(262_144)).to be(true)
    end

    it "answers from File.size, without the file being read" do
      tiny = described_class.new(limit: 1)

      expect(tiny.admits?(File.size(__FILE__))).to be(false)
    end

    it "takes a byte count, not content" do
      expect(described_class.instance_method(:admits?).arity).to eq(1)
    end

    it "offers the refusal text without a Result, for a caller that is not a tool" do
      expect(bound.message(subject: "the summarizer input", size: 5_242_880, narrower: ["decline"]))
        .to include("the summarizer input", "5242880", "262144", "decline")
    end

    it "defaults its unit to bytes" do
      expect(bound.unit).to eq("bytes")
    end

    it "is a deeply frozen value object" do
      expect(Ractor.shareable?(bound)).to be(true)
    end
  end

  describe "the bound itself" do
    it "refuses a negative ceiling loudly rather than capping to nothing" do
      expect { Lain::Tool::Bounds::Enumeration.new(limit: -1, unit: "matches") }
        .to raise_error(ArgumentError)
    end

    it "refuses a ceiling that is not a number" do
      expect { Lain::Tool::Bounds::Artifact.new(limit: "lots") }
        .to raise_error(ArgumentError, /String/)
    end

    # Strict, and the strictness is the point: `Integer()` would take "262144",
    # read "0x10" as 16 and round 2.7 down to 2, all silently. A bound that
    # arrived as the wrong type arrived from somewhere that is wrong about it.
    it "refuses a numeric-looking String rather than parsing it" do
      expect { Lain::Tool::Bounds::Artifact.new(limit: "262144") }
        .to raise_error(ArgumentError, /String/)
    end

    it "refuses a Float rather than truncating it" do
      expect { Lain::Tool::Bounds::Artifact.new(limit: 2.7) }
        .to raise_error(ArgumentError, /Float/)
    end

    # Both shapes answer the same question about a size; only what they DO with
    # the answer differs. T5, T6 and T13 all lean on that.
    it "answers admits? in both shapes" do
      expect(Lain::Tool::Bounds::Enumeration.new(limit: 1, unit: "rows"))
        .to respond_to(:admits?)
    end
  end
end
