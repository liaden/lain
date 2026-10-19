# frozen_string_literal: true

RSpec.describe Lain::CredentialPatterns do
  # The write side's four, the key block since widened from its header to its
  # whole span and the assignment to a compound name holding a literal value.
  # Written out rather than referenced so these examples compare the shipped
  # regexps against a literal, not against themselves.
  let(:write_side_today) do
    {
      "openai-style api key" => /(?<![\w-])sk-[A-Za-z0-9_-]{16,}/,
      "aws access key id" => /AKIA[0-9A-Z]{16}/,
      "pem private key block" => /-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----(?:.*?-----END [A-Z ]*PRIVATE KEY-----|.*)/m,
      "credential assignment" => Regexp.new(
        "(?<![A-Za-z0-9])(?:password|passwd|secret|api[_-]?key|token)(?:[_-](?:access[_-])?key(?:[_-]base)?)?" \
        '(?>\s*)(?:=>|:=|[:=])(?>\s*)' \
        '(?:"(?![^"\n]*#\{|\$[{(])[^"\n]+"|\'(?![^\'\n]*#\{|\$[{(])[^\'\n]+\'|' \
        '(?![-@$<:]|#\{|(?-i:ENV[\[.]|params\[|request\.))(?!(?>[^\s"\'`(\[.),;\\\\:]*)::)' \
        '(?=(?>[A-Za-z_]*)[^A-Za-z_\s"\'`(\[.),;\\\\])(?=(?>[0-9_]*)[^0-9_\s"\'`(\[.),;\\\\])' \
        '(?>[^\s"\'`(\[.),;\\\\]{6,})(?![(\[]|\.\w))',
        Regexp::IGNORECASE
      )
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

  describe "the write side's active set" do
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

  # The whole block is one span, so a mask built from it covers the short last
  # base64 line that no entropy run reaches. A block the text cuts off before
  # its END -- a bounded read, a window -- is covered to the end of the text.
  describe "the private key block" do
    let(:block) { described_class.for(:content).fetch("pem private key block") }
    let(:pem) do
      "-----BEGIN RSA PRIVATE KEY-----\n" \
        "MIIG5AIBAAKCAYEAqwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXC\n" \
        "Zm9vYmFy==\n" \
        "-----END RSA PRIVATE KEY-----\n"
    end

    it "spans BEGIN through END, the short last line inside it" do
      expect(block.match("before\n#{pem}after\n")[0]).to eq(pem.chomp)
    end

    it "spans to the end of the text when no END follows" do
      truncated = pem.lines.first(3).join

      expect(block.match("before\n#{truncated}")[0]).to eq(truncated)
    end

    it "keeps two blocks apart rather than spanning the text between them" do
      text = "#{pem}ordinary line\n#{pem}"

      expect(text.to_enum(:scan, block).map { Regexp.last_match[0] }).to eq([pem.chomp] * 2)
    end

    it "is the same shape on the write side, which refuses on the header alone" do
      expect(described_class.for(:write).fetch("pem private key block")).to equal(block)
      expect(block).to match("-----BEGIN OPENSSH PRIVATE KEY-----")
    end
  end

  describe "the credential assignment shape" do
    let(:shape) { described_class.for(:write).fetch("credential assignment") }

    it "sees the word as the last segment of a compound name holding a literal" do
      lines = ["AWS_SECRET_ACCESS_KEY=abc123def", "DB_PASSWORD=hunter2pass", "GITHUB_TOKEN=ghx_abc123",
               "OPENAI_API_KEY=sk-abc123", "STRIPE_SECRET=abc123def", "SECRET_KEY_BASE=abc123def456",
               "export SLACK_TOKEN=xoxb-abc123", %(api_token = "hunter2"), "password: hunter2pass."]

      expect(lines).to all(match(shape))
    end

    # A value that names something else -- a reference, a call, a bare word or
    # identifier -- is ordinary code, and the write side refuses a human's own
    # prose, so it may not refuse these.
    it "leaves ordinary code alone" do
      lines = ["token_count = 5", "max_tokens: 100", "note: remember this", "access_token = request.headers['X']",
               "id_token: nil", "refresh_token: params[:refresh]", "auth_token = SecureRandom.hex",
               "reset_password = true", "confirm_password: string", "page_token = resp.next",
               "client_secret: <%= ENV['X'] %>", "token_count = 123456"]

      expect(lines.grep_v(shape)).to eq(lines)
    end

    it "leaves a call, a reference, an interpolation and a short or numeric value alone" do
      lines = ["token = utf8_encode(x)", "token = response2.body", "password = hmac_sha256(key, msg)",
               "token = get_token2()", "secret = s3_bucket.key", "token = $abc123", "token = @tok3n_x",
               "token = abc12", "echo ${GITHUB_TOKEN:-unset}", %(api_key = "\#{api_key}"), "token = \#{placeholder}",
               %(token = "$(direnv exec . printenv X)"), "token = 12_345", "password: <redacted>",
               "auth_token = Lain::Token", "token = ::Token", "token: :bearer", %(token = "Bearer \#{t}")]

      expect(lines.grep_v(shape)).to eq(lines)
    end

    it "excludes a reference by its exact spelling, so a value merely starting with those letters is still seen" do
      lines = ["password=Envy2024!", "token=requestor99", "secret=Paramsx9z"]

      expect(lines).to all(match(shape))
    end

    it "accepts => and := as the assignment" do
      lines = [%(:password => "hunter2pass"), %(password := "hunter2pass")]

      expect(lines).to all(match(shape))
    end

    it "ends a bare value before a backslash, so a source escape is not part of it" do
      expect(shape.match(%(GITHUB_TOKEN=ghx_abc123\\n))[0]).to eq("TOKEN=ghx_abc123")
    end

    # A long unbroken line is what a pasted blob or a minified file hands over,
    # and a shape that backtracks over it stalls every read and write it guards.
    it "scans a 100 KB line in linear time on both sides" do
      lines = ["token=" * 16_667, "token=#{"a" * 100_000}1", "x_token=#{"a" * 100_000}(", "token=abcdefg1(" * 6_667]
      shapes = [shape, described_class.for(:content).fetch("credential literal assignment")]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      shapes.product(lines).each { |re, line| line.match?(re) }

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.2
    end

    it "ends a bare value before a backtick or trailing punctuation" do
      values = ["`DB_PASSWORD=hunter2pass`.", "(DB_PASSWORD=hunter2pass)", "DB_PASSWORD=hunter2pass;",
                "DB_PASSWORD=hunter2pass, then"].map { shape.match(_1)[0] }

      expect(values).to all(eq("PASSWORD=hunter2pass"))
    end
  end

  # A real .env line keeps the name the read side journaled before the write
  # side widened, so reason counts do not shift; only a line the old shapes
  # never saw gets the new name.
  describe "which name the read side gives an assignment" do
    it "keeps the dotenv name for a compound .env line" do
      expect(first_name_matching(:content, "GITHUB_TOKEN=ghx_abc123def\n")).to eq("dotenv assignment")
    end

    it "keeps the credential name for a bare credential word" do
      expect(first_name_matching(:content, "password: hunter2pass")).to eq("credential assignment")
    end

    it "gives the new name to a compound literal only the widened shape sees" do
      expect(first_name_matching(:content, "then set DB_PASSWORD=hunter2pass")).to eq("credential literal assignment")
    end
  end

  describe "selecting a consumer" do
    # A read must mask whatever a write refuses: every write-side sample the
    # write side refuses is named by some content-side shape.
    it "gives the content side everything the write side has" do
      samples = ["sk-#{"a" * 20}", "AKIA#{"A" * 16}", "-----BEGIN PRIVATE KEY-----", "password: hunter2",
                 "AWS_SECRET_ACCESS_KEY=abc123def", "DB_PASSWORD=hunter2pass", "GITHUB_TOKEN=ghx_abc123",
                 "OPENAI_API_KEY=sk-abc123", "STRIPE_SECRET=abc123def", "SECRET_KEY_BASE=abc123def456",
                 "export SLACK_TOKEN=xoxb-abc123", "token_count = 5", "max_tokens: 100", "note: remember this",
                 "access_token = request.headers['X']", "id_token: nil", "refresh_token: params[:refresh]",
                 "auth_token = SecureRandom.hex", "reset_password = true", "confirm_password: string",
                 "page_token = resp.next", "client_secret: <%= ENV['X'] %>"]
      unmasked = samples.select { names_matching(:write, _1).any? && names_matching(:content, _1).empty? }

      expect(described_class.for(:content).keys).to include(*described_class.for(:write).keys)
      expect(unmasked).to be_empty
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

  describe "credential-file shapes on the content side" do
    it "names each format on the content side and none on the write side" do
      lines = ["machine h login u password hunter2hunter2", "db.example:5432:app:alice:s3cretpass",
               "alice:$apr1$abc$0123456789abcdefghijk", "password s3cretpass"]
      named = /netrc|pgpass|htpasswd|msmtprc/

      expect(lines.map { names_matching(:write, _1) }).to all(be_empty)
      expect(lines.map { names_matching(:content, _1) }).to all(include(a_string_matching(named)))
    end
  end

  describe "assignment shapes on the content side" do
    it "names a pattern for a dotenv line" do
      line = "ANTHROPIC_API_KEY=sk-ant-0000000000000000000"

      expect(names_matching(:content, line)).not_to be_empty
      expect(names_matching(:content, line)).to include("dotenv assignment")
    end

    it "sees a compound credential name on both sides, the write side naming the credential" do
      line = "DATABASE_PASSWORD=hunter2pass"

      expect(names_matching(:write, line)).to eq(["credential assignment"])
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

  # `for(:content)` exists to be run over raw file bytes, and Ruby's
  # regexp engine cares about the String's ENCODING, not its contents. The
  # contract is: hand it binary. These examples are the verification that
  # `File.binread` satisfies it, and the demonstration of why the contract is
  # needed at all. Normalizing inside the table is deliberately NOT done here
  # -- that is a calibration decision, not this table's.
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

    # `^` anchors before the BOM, and a BOM is not `[ \t]`, so the line-anchored
    # shapes cannot see a name the BOM sits directly in front of. The literal
    # assignment is not anchored, so a compound credential name there is seen.
    it "sees a credential literal a BOM sits directly in front of on line 1" do
      bytes = (+"\xEF\xBB\xBFAPI_TOKEN=hunter2\n").force_encoding(Encoding::ASCII_8BIT)

      expect(names_matching(:content, bytes)).to eq(["credential literal assignment"])
    end

    it "raises on a String whose encoding says UTF-8 but whose bytes are not" do
      invalid = (+"caf\xC3\x28 SECRET_TOKEN=hunter2").force_encoding(Encoding::UTF_8)

      expect(invalid.valid_encoding?).to be(false)
      expect { names_matching(:content, invalid) }.to raise_error(ArgumentError, /invalid byte sequence/)
    end

    # The documented encoding trap: UTF-16 is not
    # ASCII-compatible, and `valid_encoding?` is TRUE, so a caller cannot use
    # that predicate to decide whether a scan is safe.
    it "raises on UTF-16 even though its valid_encoding? is true" do
      utf16 = "SECRET_TOKEN=hunter2".encode(Encoding::UTF_16)

      expect(utf16.valid_encoding?).to be(true)
      expect { names_matching(:content, utf16) }.to raise_error(Encoding::CompatibilityError)
    end
  end

  # The yaml shape needs only a colon and a space, so it matches ordinary
  # prose. Recorded, not fixed: it is honest about being a SYNTAX shape, it is
  # kept off the write side, and a later calibration should tune it rather
  # than discover it.
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
