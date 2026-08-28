# frozen_string_literal: true

require "pp"

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

  describe Lain::Tool::Bounds::Handback do
    subject(:bound) { described_class.new(limit: 32_768) }

    let(:oversized) { "x" * 40_000 }
    let(:actions) { ["send it anyway", "shorten it and send that"] }

    # Scenario: a thing under the ceiling is admitted unchanged
    it "admits content under the ceiling" do
      expect(bound.admits?("a short answer".bytesize)).to be(true)
    end

    it "admits a size at exactly the ceiling" do
      expect(bound.admits?(32_768)).to be(true)
    end

    it "does not admit a size over the ceiling" do
      expect(bound.admits?(32_769)).to be(false)
    end

    # Scenario: an oversized thing is not refused outright
    it "hands the oversized content back rather than discarding it" do
      handed = bound.overrun(subject: "your reply", content: oversized, actions:)

      expect(handed.content).to eq(oversized)
    end

    it "hands back every byte, never a preview" do
      handed = bound.overrun(subject: "your reply", content: oversized, actions:)

      expect(handed.content.bytesize).to eq(40_000)
    end

    it "measures the content itself rather than trusting a count it was handed" do
      handed = bound.overrun(subject: "your reply", content: oversized, actions:)

      expect(handed.size).to eq(40_000)
    end

    # The measurement cannot disagree with the content, because there is nowhere
    # to hand a size in. A tool holding both an output String and its bytesize is
    # one character from passing the wrong one; here the wrong one is unsayable.
    it "takes no size, so no caller can pass content where a count belongs" do
      expect(described_class.instance_method(:overrun).parameters.map(&:last))
        .to contain_exactly(:subject, :content, :actions)
    end

    # Scenario: the bound refuses to report without an action to offer
    it "refuses to hand anything back with no action named" do
      expect { bound.overrun(subject: "your reply", content: oversized, actions: []) }
        .to raise_error(ArgumentError, /action/)
    end

    # An overrun names something that overran. A caller reaching for one over
    # content that fits has confused its two branches, and a value that agreed
    # would report a ceiling breach that did not happen.
    it "refuses to call a thing that fits an overrun" do
      expect { bound.overrun(subject: "your reply", content: "short", actions:) }
        .to raise_error(ArgumentError, /fits/)
    end

    # `Effect::Handler::Live` turns that raise into `Result.error(e.message)`, so
    # a sentence measuring the content would reach the model looking exactly like
    # a bound's refusal while asserting the opposite of one.
    it "reports that raise as a bug in the call, not as a measurement" do
      expect { bound.overrun(subject: "your reply", content: "short", actions:) }
        .to raise_error(ArgumentError, /Handback#measure|#admits\?/)
    end

    it "names no measurement in that raise" do
      raised = begin
        bound.overrun(subject: "your reply", content: "short", actions:)
      rescue ArgumentError => e
        e
      end

      expect(raised.message).not_to match(/\d/)
    end

    # Scenario: measuring in one call, with no guard for a caller to forget
    it "reports nothing when the content fits" do
      expect(bound.measure(subject: "your reply", content: "short", actions:)).to be_nil
    end

    it "hands back an overrun when the content does not fit" do
      expect(bound.measure(subject: "your reply", content: oversized, actions:))
        .to be_a(Lain::Tool::Bounds::Overrun)
    end

    it "measures the same boundary as admits? does, from the other side" do
      expect(bound.measure(subject: "your reply", content: "x" * 32_768, actions:)).to be_nil
    end

    it "reports the first byte over" do
      expect(bound.measure(subject: "your reply", content: "x" * 32_769, actions:).size).to eq(32_769)
    end

    # The guard has to sit on the door the consumers are told to use, and the
    # example for `#overrun` does not reach it: `#measure` asks for a byte count
    # before it decides whether to keep anything, so an unguarded one would die
    # at `bytesize` and reach the model as a crash-shaped sentence.
    it "refuses content that is not a String at the primary door too" do
      expect { bound.measure(subject: "your reply", content: 40_000, actions:) }
        .to raise_error(ArgumentError, /Integer/)
    end

    it "refuses nil content at the primary door, naming the class" do
      expect { bound.measure(subject: "your reply", content: nil, actions:) }
        .to raise_error(ArgumentError, /NilClass/)
    end

    it "refuses actions that are not a list, rather than dying inside the map" do
      expect { bound.overrun(subject: "your reply", content: oversized, actions: "send it anyway") }
        .to raise_error(ArgumentError, /Array/)
    end

    it "refuses no actions at all, naming the class rather than failing obscurely" do
      expect { bound.overrun(subject: "your reply", content: oversized, actions: nil) }
        .to raise_error(ArgumentError, /NilClass/)
    end

    it "names no byte of the content when it refuses" do
      raised = begin
        bound.overrun(subject: "your reply", content: "SECRETPAYLOAD", actions:)
      rescue ArgumentError => e
        e
      end

      expect("#{raised.class}: #{raised.message}").not_to include("SECRETPAYLOAD")
    end

    it "refuses a ceiling that is not an Integer" do
      expect { described_class.new(limit: "lots") }.to raise_error(ArgumentError, /String/)
    end

    it "is a deeply frozen value object" do
      expect(Ractor.shareable?(bound)).to be(true)
    end
  end

  describe Lain::Tool::Bounds::Overrun do
    subject(:overrun) { bound.overrun(subject: "your reply", content:, actions:) }

    let(:bound) { Lain::Tool::Bounds::Handback.new(limit: 32_768) }
    let(:content) { "x" * 40_000 }
    let(:actions) { ["send it anyway", "shorten it and send that"] }
    let(:payloaded) { bound.overrun(subject: "your reply", content: "SECRETPAYLOAD" * 5_000, actions:) }

    # Scenario: the report names the measurement and the ceiling
    it "states the measurement" do
      expect(overrun.message).to include("40000")
    end

    it "states the ceiling" do
      expect(overrun.message).to include("32768")
    end

    it "names what overran, in the reader's terms" do
      expect(overrun.message).to include("your reply")
    end

    it "names every action the caller offered" do
      expect(overrun.message).to include("send it anyway", "shorten it and send that")
    end

    it "reports the ceiling it overran, for a caller composing its own sentence" do
      expect(overrun.limit).to eq(32_768)
    end

    # The sentence and the payload are separate readers, and this is the
    # mechanical statement of it: a method with no parameters cannot be handed
    # the content by a caller that meant to hand it the count.
    it "builds its sentence from no arguments at all" do
      expect(described_class.instance_method(:message).parameters).to be_empty
    end

    it "keeps the payload out of the sentence it composes" do
      payload = "SECRETPAYLOAD" * 5_000

      expect(bound.overrun(subject: "your reply", content: payload, actions:).message)
        .not_to include("SECRETPAYLOAD")
    end

    # The caller picks the affordance: a channel with a human offers the
    # sentence and can still send `content`; one without turns the same sentence
    # into an error Result and sends nothing.
    it "composes an error Result for a caller with no one to ask" do
      expect(overrun.refusal).to be_a(Lain::Tool::Result).and be_error
    end

    it "carries the same sentence into that Result" do
      expect(overrun.refusal.content).to eq(overrun.message)
    end

    it "keeps the payload out of that Result too" do
      payload = "SECRETPAYLOAD" * 5_000

      expect(bound.overrun(subject: "your reply", content: payload, actions:).refusal.content)
        .not_to include("SECRETPAYLOAD")
    end

    it "still offers the content to a caller that asks for it by name" do
      expect(overrun.content).to eq(content)
    end

    it "refuses content that is not a String, naming the class rather than the value" do
      expect { bound.overrun(subject: "your reply", content: 40_000, actions:) }
        .to raise_error(ArgumentError, /Integer/)
    end

    it "cannot be built with no action, whichever door it is built through" do
      expect { described_class.new(bound:, subject: "your reply", content:, actions: []) }
        .to raise_error(ArgumentError, /action/)
    end

    it "is a deeply frozen value object" do
      expect(Ractor.shareable?(overrun)).to be(true)
    end

    # A bound is not type-checked anywhere else in this file, and here it must be:
    # every shape answers `admits?` and `limit`, so an enumeration's row cap would
    # be printed as a byte ceiling and read as one.
    it "refuses a bound that counts something other than bytes" do
      rows = Lain::Tool::Bounds::Enumeration.new(limit: 10, unit: "rows")

      expect { described_class.new(bound: rows, subject: "your reply", content:, actions:) }
        .to raise_error(ArgumentError, /Handback/)
    end

    it "refuses a bare Integer where a bound belongs" do
      expect { described_class.new(bound: 32_768, subject: "your reply", content:, actions:) }
        .to raise_error(ArgumentError, /Integer/)
    end

    # Scenario: the payload does not walk out through a printer
    #
    # `Data` renders every member, so the default `#inspect` puts the whole
    # payload into any `"#{over}"` a consumer writes -- and the Journal is NDJSON,
    # where one oversized line is the failure this bound exists to prevent.
    it "withholds the content from #inspect" do
      expect(payloaded.inspect).not_to include("SECRETPAYLOAD")
    end

    it "keeps #inspect a constant size however large the content is" do
      expect(payloaded.inspect.bytesize).to be < 200
    end

    it "still names the measurement, the ceiling and the subject when inspected" do
      expect(payloaded.inspect).to include("32768", "65000", "your reply")
    end

    it "says the content is withheld rather than pretending there is none" do
      expect(payloaded.inspect).to include("WITHHELD")
    end

    it "withholds it from #to_s too, which is what interpolation reaches" do
      # The interpolation is the subject, not a long way of writing `to_s`: the
      # leak this guards is `log << "bounded: #{over}"`, so the cop is answered
      # rather than obeyed.
      expect("#{payloaded}").not_to include("SECRETPAYLOAD") # rubocop:disable Style/RedundantInterpolation
    end

    it "withholds it from a format specifier" do
      expect(format("%s", payloaded)).not_to include("SECRETPAYLOAD")
    end

    # An inspector that walks members itself never calls `#inspect`, which is the
    # gap `Provider::Ollama::Deployment::Cloud` records for a live credential.
    # `pp` is that shape, and so is the suite's own object formatter.
    it "withholds it from pp, which walks the members rather than asking" do
      expect(PP.pp(payloaded, +"")).not_to include("SECRETPAYLOAD")
    end

    it "withholds it from the formatter a failing example prints its subject with" do
      expect(RSpec::Support::ObjectFormatter.format(payloaded)).not_to include("SECRETPAYLOAD")
    end

    # Stated as the boundary rather than as a leak: `Data` gives every value
    # `#to_h`, pattern matching and whole-object serialisation, none of which is
    # reached without naming the payload or asking for the whole object.
    it "still yields the content to a caller that destructures for it" do
      expect(payloaded.to_h[:content].bytesize).to eq(65_000)
    end

    # Frozen on both sides of the handback, and the symmetry is the point: a
    # caller that goes on mutating its own buffer must not be able to change
    # what the overrun says it holds.
    it "does not hand back the caller's own String" do
      expect(overrun.content).not_to be(content)
    end

    it "stays shareable when its subject arrives as a Symbol" do
      expect(Ractor.shareable?(bound.overrun(subject: :reply, content:, actions:))).to be(true)
    end

    it "stays shareable when its actions arrive interpolated" do
      limit = 32_768

      expect(Ractor.shareable?(bound.overrun(subject: "your reply", content:, actions: ["trim to #{limit}"])))
        .to be(true)
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
    # the answer differs. The callers that carry bounds all lean on that.
    it "answers admits? in both shapes" do
      expect(Lain::Tool::Bounds::Enumeration.new(limit: 1, unit: "rows"))
        .to respond_to(:admits?)
    end
  end
end
