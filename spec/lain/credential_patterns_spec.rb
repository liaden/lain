# frozen_string_literal: true

RSpec.describe Lain::CredentialPatterns do
  # The write side's four, transcribed from the table as it read before the
  # move. Written out rather than referenced so these examples compare the
  # shipped regexps against a literal, not against themselves.
  let(:write_side_today) do
    {
      "openai-style api key" => /(?<![\w-])sk-[A-Za-z0-9_-]{16,}/,
      "aws access key id" => /AKIA[0-9A-Z]{16}/,
      "pem private key block" => /-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----/,
      "credential assignment" => /\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+/i
    }
  end

  def names_matching(consumer, text)
    described_class.for(consumer).filter_map { |name, shape| name if shape.match?(text) }
  end

  # What a consumer that journals ONE name actually reports: the middleware
  # takes `.find`, so iteration order decides which name a line is refused
  # under.
  def first_name_matching(consumer, text)
    described_class.for(consumer).find { |_name, shape| shape.match?(text) }&.first
  end

  describe "the write side's active set is unchanged" do
    it "holds exactly the four names the write side used before the move" do
      expect(described_class.for(:write).keys).to eq(write_side_today.keys)
    end

    it "holds the same regexps, source and options both" do
      expect(described_class.for(:write)).to eq(write_side_today)
    end

    it "is the very table the middleware guards with, so the two cannot drift" do
      expect(Lain::Middleware::RefuseSecretWrites::PATTERNS).to equal(described_class.for(:write))
    end

    it "is frozen, so a consumer cannot widen the other's set by mutating its own" do
      expect(described_class.for(:write)).to be_frozen
      expect(described_class.for(:content)).to be_frozen
    end
  end

  # The regression the lookbehind exists for: unanchored, the key shape matched
  # inside hyphenated prose and refused a benign write under a pattern name it
  # never honestly matched. Asserted at the table so the move cannot lose it.
  describe "the api-key shape still stands alone" do
    let(:key) { described_class.for(:write).fetch("openai-style api key") }

    it "keeps the lookbehind rather than a bare word boundary" do
      expect(key.source).to include('(?<![\w-])')
    end

    it "does not match a hyphenated slug that merely contains sk-" do
      expect(key).not_to match("my-project-sk-#{"a" * 20}")
      expect(key).not_to match("ask-someone-to-help-with-planning-next-year")
    end

    it "still matches a real-shaped key at start, mid-sentence and after punctuation" do
      bodies = ["sk-#{"a" * 20}", "my key is sk-#{"a" * 20}", "KEY=sk-#{"a" * 20}"]

      expect(bodies).to all(match(key))
    end
  end

  describe "selecting a consumer" do
    it "gives the content side everything the write side has" do
      expect(described_class.for(:content)).to include(described_class.for(:write))
    end

    it "gives the content side shapes the write side does not have" do
      extra = described_class.for(:content).keys - described_class.for(:write).keys
      expect(extra).not_to be_empty
    end

    it "names the known consumers when asked for one that does not exist" do
      expect { described_class.for(:writes) }.to raise_error(ArgumentError, /:writes.*write.*content/m)
    end
  end

  # The card's point: one table so the sides cannot drift, but the read side
  # needs shapes the write side must not gain. A single undifferentiated
  # constant can only satisfy one of those.
  describe "a widened shape does not reach the write side" do
    let(:prose) { "note: remember this" }

    it "matches the content side's yaml assignment shape" do
      expect(names_matching(:content, prose)).to include("yaml assignment")
    end

    it "matches nothing at all in the write set" do
      expect(names_matching(:write, prose)).to be_empty
    end

    it "does not refuse a memory_write whose body is that prose" do
      journal = RecordingChannel.new
      guard = Lain::Middleware::RefuseSecretWrites.new(journal:)
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "memory_write",
                                          input: { "id" => "n", "description" => "d", "body" => prose })
      called = false
      guard.call({ effect:, context: nil }) do |env|
        called = true
        env.merge(result: Lain::Tool::Result.ok("wrote"))
      end

      expect(called).to be(true)
      expect(journal.events).to be_empty
    end
  end

  describe "assignment shapes on the content side" do
    it "names a pattern for a dotenv line" do
      line = "ANTHROPIC_API_KEY=sk-ant-0000000000000000000"

      expect(names_matching(:content, line)).not_to be_empty
      expect(names_matching(:content, line)).to include("dotenv assignment")
    end

    # The discriminator that earns the content set its existence: a compound
    # environment-variable name has no word boundary before "PASSWORD", so the
    # write side's name-gated assignment shape cannot see it.
    it "sees a compound credential name the write side's word boundary misses" do
      line = "DATABASE_PASSWORD=hunter2"

      expect(names_matching(:write, line)).to be_empty
      expect(names_matching(:content, line)).to include("dotenv assignment")
    end

    it "names a pattern for a quoted toml assignment" do
      expect(names_matching(:content, %(api_token = "hunter2"))).to include("toml assignment")
    end

    it "reads a dotenv assignment anywhere in multi-line file bytes, not only the first line" do
      bytes = "# comment\n\nexport SESSION_SECRET=hunter2\n"

      expect(names_matching(:content, bytes)).to include("dotenv assignment")
    end

    # WRITE merges FIRST, so a line that is both an assignment and a known
    # issuer prefix is journaled under the shape that says more. Reversing the
    # merge leaves every other example in this file green.
    it "names the issuer prefix, not the syntax, when a line matches both" do
      line = %(api_key = "sk-#{"a" * 20}")

      expect(names_matching(:content, line)).to include("openai-style api key", "toml assignment")
      expect(first_name_matching(:content, line)).to eq("openai-style api key")
    end
  end

  # S1. `for(:content)` exists to be run over raw file bytes, and Ruby's
  # regexp engine cares about the String's ENCODING, not its contents. The
  # contract is: hand it binary. These examples are the verification that
  # `File.binread` satisfies it, and the demonstration of why the contract is
  # needed at all. Normalizing inside the table is deliberately NOT done here
  # -- that is T10's decision to make.
  describe "the encoding contract for raw file bytes" do
    it "scans ASCII-8BIT bytes holding high bytes, and still finds the assignment" do
      bytes = (+"caf\xC3\xA9 notes\nSECRET_TOKEN=hunter2\n").force_encoding(Encoding::ASCII_8BIT)

      expect(names_matching(:content, bytes)).to include("dotenv assignment")
    end

    it "scans a BOM'd blob without raising" do
      bytes = (+"\xEF\xBB\xBF# config\nAPI_TOKEN=hunter2\n").force_encoding(Encoding::ASCII_8BIT)

      expect { names_matching(:content, bytes) }.not_to raise_error
      expect(names_matching(:content, bytes)).to include("dotenv assignment")
    end

    # Known limitation, recorded rather than fixed: `^` anchors before the BOM,
    # and a BOM is not `[ \t]`, so a name the BOM sits directly in front of is
    # invisible. Only line 1 of a BOM'd file is affected. T10 decides whether
    # to strip it.
    it "does NOT see an assignment a BOM sits directly in front of on line 1" do
      bytes = (+"\xEF\xBB\xBFAPI_TOKEN=hunter2\n").force_encoding(Encoding::ASCII_8BIT)

      expect(names_matching(:content, bytes)).to be_empty
    end

    it "raises on a String whose encoding says UTF-8 but whose bytes are not" do
      invalid = (+"caf\xC3\x28 SECRET_TOKEN=hunter2").force_encoding(Encoding::UTF_8)

      expect(invalid.valid_encoding?).to be(false)
      expect { names_matching(:content, invalid) }.to raise_error(ArgumentError, /invalid byte sequence/)
    end

    # The documented Approval::Risk trap (risk.rb:322): UTF-16 is not
    # ASCII-compatible, and `valid_encoding?` is TRUE, so a caller cannot use
    # that predicate to decide whether a scan is safe.
    it "raises on UTF-16 even though its valid_encoding? is true" do
      utf16 = "SECRET_TOKEN=hunter2".encode(Encoding::UTF_16)

      expect(utf16.valid_encoding?).to be(true)
      expect { names_matching(:content, utf16) }.to raise_error(Encoding::CompatibilityError)
    end
  end

  # S2. The yaml shape needs only a colon and a space, so it matches ordinary
  # prose. Recorded, not fixed: it is honest about being a SYNTAX shape, it is
  # kept off the write side, and T10 should calibrate rather than discover.
  describe "the yaml assignment shape is imprecise by construction" do
    let(:prose) { "TODO: fix this" }

    it "names ordinary prose of the form 'word: text'" do
      expect(first_name_matching(:content, prose)).to eq("yaml assignment")
    end

    it "reaches nothing on the write side, which is what keeps the imprecision harmless" do
      expect(names_matching(:write, prose)).to be_empty
    end
  end

  describe "hyphenated prose is not a key" do
    let(:prose) { "ask-someone-to-help-with-this" }

    it "matches nothing on the write side" do
      expect(names_matching(:write, prose)).to be_empty
    end

    it "matches nothing on the content side either" do
      expect(names_matching(:content, prose)).to be_empty
    end
  end

  # A pattern name inside the reserved namespace would make `decline?` report a
  # genuine credential hit as a judgment call -- the exact inverse of the
  # mislabel the namespace exists to fix, and silent.
  describe "the reserved decline namespace" do
    it "refuses to build a table holding a name inside it" do
      expect { described_class.unreserved("decline:oracle" => /x/) }
        .to raise_error(/reserved "decline:" namespace/)
    end

    it "names the offending pattern when it refuses" do
      expect { described_class.unreserved("decline:oracle" => /x/) }
        .to raise_error(/decline:oracle/)
    end

    it "builds a table whose names are all outside it" do
      table = described_class.unreserved("aws access key id" => /AKIA/)

      expect(table).to eq("aws access key id" => /AKIA/)
      expect(table).to be_frozen
    end

    it "holds no reserved name in any shipped set" do
      %i[write content].each do |consumer|
        expect(described_class.for(consumer).keys.select { |name| described_class.decline?(name) }).to be_empty
      end
    end

    it "is the one prefix the middleware's decline? tests, so the two cannot drift" do
      expect(Lain::Middleware::RefuseSecretWrites::DECLINE_PREFIX).to eq(described_class::DECLINE_PREFIX)
      expect(Lain::Middleware::RefuseSecretWrites).to be_decline(described_class::DECLINE_PREFIX)
    end
  end
end
