# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Regions do
  def detect(content) = described_class.detect(content)

  def digests(content) = detect(content).map(&:digest)

  # Long enough and random enough that no threshold under discussion misses it,
  # so an example about POSITION never fails for a reason about ENTROPY.
  let(:secret) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }

  # `yaml assignment` is LINE-ANCHORED, so a `Note:` sitting mid-paragraph is not
  # reached by the shape that floods and this fixture would prove nothing. Both
  # colon lines start at column 0 deliberately.
  let(:prose) do
    <<~PROSE
      # Lain

      Lain is an agent harness built as a study bench. The agent is the vehicle
      and the bench is the deliverable.

      Note: this line begins at column 0 so the flooding shape actually reaches it.
      Warning: so does this one, and neither may report a region.

      Run the suite with rake, and read the output before believing it.
    PROSE
  end

  describe ".detect" do
    context "when a dotenv line assigns an API key" do
      let(:content) do
        <<~ENV
          # configuration for the local run
          Run this before anything else.
          API_KEY=#{secret}
          The line above is the only interesting one.
        ENV
      end

      it "reports exactly one region" do
        expect(detect(content).size).to eq(1)
      end

      # Both readings of the AC at once. The region sits inside the assignment,
      # and it excludes the NAME -- T15 renders an unreleased region as
      # `<redacted:N>`, and a region covering `API_KEY=...` would erase the key
      # name that T15's "the structure survives" contract promises to keep.
      it "covers the assignment's value and not its name" do
        region = detect(content).first

        expect(content.byteslice(region.start, region.length)).to eq(secret)
        expect(content.byteslice(region.start, region.length)).not_to include("API_KEY")
        expect(content.lines.find { |line| line.include?(secret) }).to include("API_KEY=")
      end

      # `API_KEY=` is both a dotenv assignment and the write side's name-gated
      # `credential assignment`. The table's own order decides, so the region is
      # named by the shape that says more.
      it "names the shape that matched, preferring the more specific one" do
        expect(detect(content).first.reason).to eq("credential assignment")
      end

      it "attributes it to the pattern detector" do
        expect(detect(content).first).to have_attributes(detector: :pattern, entropy?: false)
      end

      it "refuses a detector it does not know" do
        expect { described_class::Region.new(start: 0, bytes: "x", reason: "y", detector: :guess) }
          .to raise_error(ArgumentError, /unknown detector/)
      end
    end

    context "when a comment line is inserted above a region" do
      let(:before) { "API_KEY=#{secret}\ntrailing line\n" }
      let(:after) { "# a note added later\nAPI_KEY=#{secret}\ntrailing line\n" }

      # The whole point of the card: identity is the bytes, never the offset.
      it "leaves the region's digest unchanged" do
        expect(digests(after)).to eq(digests(before))
      end

      it "moves the region's offset" do
        expect(detect(after).first.start).to be > detect(before).first.start
      end
    end

    context "when a second key is added elsewhere in the file" do
      let(:other) { "Zx4Wn7Qv2Rt9Yb5Ke1Mh8Jd3Fg6Ls0Pc4Xa7Nu2Iy5Or8Tw1" }
      let(:before) { "first line\nAPI_KEY=#{secret}\nlast line\n" }
      let(:after) { "first line\nAPI_KEY=#{secret}\nOTHER_KEY=#{other}\nlast line\n" }

      it "gains exactly one digest" do
        expect(digests(after).size).to eq(digests(before).size + 1)
      end

      it "leaves the existing digests unchanged" do
        expect(digests(after)).to include(*digests(before))
      end
    end

    context "when a high-entropy token carries no recognizable prefix" do
      # A bare token on its own line: no assignment, no issuer prefix, nothing
      # for the pattern set to see.
      let(:content) { "the value is\n#{secret}\nand that was it\n" }

      it "reports it" do
        expect(detect(content).size).to eq(1)
        expect(content.byteslice(*detect(content).first.then { [_1.start, _1.length] })).to eq(secret)
      end

      it "names entropy as the reason" do
        expect(detect(content).first.reason).to eq("high-entropy token")
      end

      # Triage and a match must stay tellable apart without string-comparing a
      # reason: the release prompt says different things about each, and the
      # Journal records which detector spoke.
      it "attributes it to the entropy detector" do
        expect(detect(content).first).to have_attributes(detector: :entropy, entropy?: true)
      end
    end

    # Hex maxes out at 4.0 bits/char and so can never clear the base64 floor of
    # 4.2 -- it needs its own branch, and before these examples that branch had
    # negative controls only. Nothing made it fire in the affirmative, so both of
    # its constants could be moved out of reach with the suite still green.
    context "when a bare hex token is long and unpredictable" do
      let(:hex_key) { "9f8e7d6c5b4a39281706f5e4d3c2b1a0" }

      it "reports a 32-character hex key" do
        expect(detect("the value is #{hex_key} and that was it\n").map(&:bytes)).to eq([hex_key])
      end

      it "names entropy as the reason" do
        expect(detect(hex_key).map(&:reason)).to eq(["high-entropy token"])
      end

      # The floor pinned from both sides: 20 bytes is reported, 19 is not. The
      # lengths are LITERAL and not derived from `HEX_LENGTH` on purpose -- an
      # example that slices its fixture to the constant under test moves with it
      # and can never fail, which is how the first draft of this pair passed
      # against a floor of 10.
      it "reports a 20-byte hex token, which is the length floor" do
        at_floor = "9f8e7d6c5b4a39281706"

        expect(detect("value #{at_floor} end").map(&:bytes)).to eq([at_floor])
      end

      # Named for what it actually pins. A BARE 19-byte run is below `TOKEN`'s own
      # `{20,}` minimum, so it is never a candidate and `HEX_LENGTH` never gets to
      # speak -- which is why no mutant of `HEX_LENGTH` can fail THIS example.
      it "ignores a bare 19-byte run, which is below the token scanner's minimum" do
        below = "9f8e7d6c5b4a3928170"

        expect(detect("value #{below} end")).to be_empty
      end

      # `high_entropy?` has TWO callers, and only the entropy scanner is
      # TOKEN-filtered. An assignment's VALUE reaches it through
      # `qualifies? -> secret_shaped?` with no length pre-filter at all, so
      # `HEX_LENGTH` binds in BOTH directions on this path. Lowering it to 10
      # makes this line report a region; nothing else in the file covers that.
      it "ignores a short hex assignment value, which no token filter guards" do
        expect(detect("blob = 3f5a9c2e1d7b\n")).to be_empty
      end
    end

    context "when the content is ordinary prose" do
      it "reports nothing" do
        expect(detect(prose)).to be_empty
      end
    end

    # The gate, pinned from both sides. Without it the assignment shapes match
    # `^ident = value`, which IS Ruby assignment syntax, and every source file
    # the agent reads yields regions.
    context "when an assignment is ordinary code or prose" do
      {
        "an integer assignment" => "x = 1",
        "a boolean constant" => "DEBUG = true",
        "a colon in prose" => "Note: this is important",
        "a toml setting" => 'format = "terse"',
        "an rspec let" => 'let(:path) { "a/b" }',
        "a uuid fixture" => "id = 550e8400-e29b-41d4-a716-446655440000",
        "a long file path" => "spec/lain/frontend/neovim/inbox_view_spec.rb",
        # Long, hex-legal and entirely predictable -- the padding run that a
        # threshold of zero would report and a threshold worth having will not.
        "a run of zero bytes written as hex" => "0000000000000000000000000000",
        "a repeated hex nibble" => "abababababababababababababab"
      }.each do |label, line|
        it "reports nothing for #{label}" do
          expect(detect(line)).to be_empty
        end
      end
    end

    # A value-shape test alone cannot see this, which is why the name is matched
    # too -- and matched as a SUBSTRING, because `DATABASE_PASSWORD` has no word
    # boundary before `PASSWORD`.
    context "when a compound name assigns a short, low-entropy secret" do
      it "reports it anyway" do
        regions = detect("DATABASE_PASSWORD=hunter2pass\n")

        expect(regions.map(&:bytes)).to eq(["hunter2pass"])
      end

      it "reports a passphrase no entropy threshold would reach" do
        expect(detect("SESSION_SECRET=correct-horse-battery-staple\n").map(&:bytes))
          .to eq(["correct-horse-battery-staple"])
      end

      # `hunter2` is seven bytes and is the exact case the name-substring gate was
      # argued from, so a floor that discards it would delete the recall the gate
      # exists to buy. The floor is pinned from both sides here: seven bytes is
      # reported, five is not.
      it "reports the seven-byte value the gate was designed around" do
        expect(detect("DATABASE_PASSWORD=hunter2\n").map(&:bytes)).to eq(["hunter2"])
      end

      it "misses a name-gated value below the substance floor" do
        expect(detect("DATABASE_PASSWORD=hunt1\n")).to be_empty
      end

      # Six exactly. Without this the floor is only pinned to the range [6, 7] --
      # `hunter2` is seven bytes, so a floor of 7 satisfies every other example
      # here while measurably changing 15 regions across the repo.
      it "reports a six-byte value, which is the floor itself" do
        expect(detect("DATABASE_PASSWORD=hunt12\n").map(&:bytes)).to eq(["hunt12"])
      end
    end

    # Every line here is real, taken from this repository, and every one produced
    # a region before the substance floor. In T15 each is a prompt reading
    # "release the value `)`?" -- which is what makes a name hint over a trivial
    # value worse than useless: it spends the human's attention budget on syntax.
    context "when a name hint sits over a value with no substance" do
      {
        "a keyword argument whose value is elsewhere" =>
          "@config = config || build_config(api_key:, api_base:)",
        "a hash rocket in a YARD comment" =>
          "# @param prices [Hash{String=>Price}] family/model token => Price",
        "a zero in a keyword list" =>
          "cache_creation_input_tokens: 0, cache_read_input_tokens: 0)",
        "an integer constant" => "DEFAULT_MAX_TOKENS = 1024",
        "a closing brace" => "TOKENS = {",
        # Long enough to clear the byte floor on punctuation alone, which is why
        # the floor also requires an alphanumeric.
        "a separator constant" => 'SECTION_TOKEN = "========"'
      }.each do |label, line|
        it "reports nothing for #{label}" do
          expect(detect(line)).to be_empty
        end
      end
    end

    # Quotes belong to the file's syntax, not to the secret. Including them would
    # split one secret across two digests -- quoted and unquoted differ, so T14's
    # cache misses -- and, decisively, masking a span that carries its own
    # delimiters destroys the quoting that made the file parse.
    context "when a value is quoted" do
      let(:double) { %(API_KEY="#{secret}"\n) }
      let(:single) { %(API_KEY='#{secret}'\n) }

      it "excludes double quotes from the region" do
        expect(detect(double).map(&:bytes)).to eq([secret])
      end

      it "excludes single quotes from the region" do
        expect(detect(single).map(&:bytes)).to eq([secret])
      end

      it "digests a quoted value identically to an unquoted one" do
        expect(digests(double)).to eq(digests("API_KEY=#{secret}\n"))
      end

      it "leaves the file parseable when the region is masked" do
        region = detect(double).first
        masked = double.dup.tap { _1[region.start, region.length] = "<redacted:1>" }

        expect(masked).to eq(%(API_KEY="<redacted:1>"\n))
      end
    end

    # The yaml shape needs only a colon and a space, so its NAME arm would admit
    # any `word: text` line in prose or code. Value-shape only for it.
    context "when a yaml-shaped line carries a credential-ish name" do
      # The first word of the value has to clear the substance floor on its own,
      # or the floor kills this line whether or not yaml keeps its name arm --
      # and then the example proves nothing about the arm.
      it "reports nothing on the strength of the name alone" do
        expect(detect("session: correlation identifier for the run\n")).to be_empty
      end

      it "still reports when the value is secret-shaped" do
        expect(detect("config: #{secret}\n").map(&:bytes)).to eq([secret])
      end

      # Nothing real is lost by dropping yaml's name arm: a genuinely named
      # credential is matched by `credential assignment` directly, and a real
      # secrets.yml is gated by PATH before its content is ever read.
      it "still reports a named credential through the credential-assignment shape" do
        expect(detect("password: hunter2pass\n"))
          .to contain_exactly(have_attributes(reason: "credential assignment", bytes: "hunter2pass"))
      end
    end

    # Measured, not asserted from taste. `for(:content)` alone matches 95 of this
    # repo's 134 markdown files -- the number T9's own docstring records -- and
    # 86.0% of `lib/` and 95.4% of `spec/`, which would make every file the agent
    # reads park a pending. These examples exist so a future widening trips a spec
    # rather than waiting to be re-measured.
    context "with real files from this repository" do
      def repo_path(name) = File.expand_path("../../../#{name}", __dir__)

      def repo_files(glob) = Dir.glob(File.expand_path("../../../#{glob}", __dir__))

      it "finds nothing in this project's own instructions" do
        expect(detect(File.binread(repo_path("CLAUDE.md")))).to be_empty
      end

      it "finds nothing in the credential table it consumes" do
        expect(detect(File.binread(repo_path("lib/lain/credential_patterns.rb")))).to be_empty
      end

      # The plan doc carries one deliberately fake Anthropic key. Finding exactly
      # it, in a 1700-line prose document, is the positive and the negative
      # control in one assertion.
      it "finds only the sample key in the plan that specified it" do
        regions = detect(File.binread(repo_path("planning/specs/chunk-project-root-and-secret-boundary.md")))

        expect(regions.map(&:reason)).to eq(["openai-style api key"])
        expect(regions.first.bytes).to start_with("sk-ant-")
      end

      # Measured at 6.0% of 599 files when this landed, against the 86.0% the
      # ungated shapes produce. The bound is a flood alarm rather than a fixture,
      # so it has headroom -- but only about half again, not the 3x it carried
      # when it was first calibrated at a rate of 11.7%.
      it "keeps the rate over this library's own source well under a flood" do
        sources = repo_files("lib/lain/**/*.rb")
        matched = sources.count { |file| detect(File.binread(file)).any? }

        expect(sources.size).to be > 500
        expect(matched.fdiv(sources.size)).to be < 0.09
      end
    end

    context "when a UTF-8 BOM precedes a key on line 1" do
      # T9 pinned that `^` anchors BEFORE a BOM and a BOM is not `[ \t]`, so the
      # patterns cannot see line 1 at all. A dotenv file written by a Windows
      # editor is exactly where that matters, so the BOM is skipped here -- and
      # the offsets must still index the ORIGINAL bytes, or T15 masks the wrong
      # span.
      # `SESSION=hunter2pass` is reachable ONLY by the line-anchored dotenv shape:
      # the value is too short and too dull for entropy, and `session` is not in
      # the write side's unanchored `credential assignment` vocabulary. So this
      # fixture fails outright if the BOM is not skipped, where `API_KEY=` would
      # have been found anyway by an unanchored shape and hidden the defect.
      let(:content) { "\xEF\xBB\xBFSESSION=hunter2pass\n".b }

      it "still finds the key" do
        expect(detect(content).size).to eq(1)
      end

      it "reports an offset into the original bytes" do
        region = detect(content).first

        expect(content.byteslice(region.start, region.length)).to eq("hunter2pass")
      end

      it "digests it identically to the same file without the BOM" do
        expect(digests(content)).to eq(digests("SESSION=hunter2pass\n"))
      end
    end

    context "when the bytes are not decodable" do
      # `valid_encoding?` answers TRUE for every UTF-16 String, which then raises
      # Encoding::CompatibilityError -- NOT an ArgumentError -- out of the first
      # Regexp. `risk.rb:322` and the `for(:content)` encoding contract both
      # record it; this is the consumer that has to survive it.
      let(:utf16) { "API_KEY=#{secret}\n".encode(Encoding::UTF_16LE) }
      let(:binary) { Random.new(20_260_807).bytes(4096) }

      it "does not raise on UTF-16" do
        expect { detect(utf16) }.not_to raise_error
      end

      it "does not raise on random binary" do
        expect { detect(binary) }.not_to raise_error
      end

      it "returns a region set for each" do
        expect(detect(utf16)).to be_an(Array).and be_frozen
        expect(detect(binary)).to be_an(Array).and be_frozen
      end

      it "does not raise on invalid UTF-8" do
        expect { detect("key=\xC3\x28#{secret}") }.not_to raise_error
      end
    end

    context "when the same bytes are scanned twice" do
      let(:content) { "A=#{secret}\nnoise\nB=#{secret.reverse}\n" }

      it "returns equal region sets in the same order" do
        expect(detect(content)).to eq(detect(content))
        expect(detect(content).size).to eq(2)
      end

      # The COUNT is asserted alongside the order because a sort that reverses the
      # scan makes the coalescer swallow both regions into one, and a single
      # region is trivially "in ascending order".
      it "returns them in ascending offset order" do
        expect(detect(content).map(&:start))
          .to eq([content.byteindex(secret), content.byteindex(secret.reverse)])
      end

      # The shapes deliberately disagree with the offsets here: the entropy run
      # comes FIRST in the file but LAST in the table's precedence order. Sorting
      # candidates by anything other than offset reorders the output.
      it "orders by offset even when the earlier region has the lower precedence" do
        mixed = "#{secret}\nAPI_KEY=sk-abcdefghijklmnopqrst\n"

        expect(detect(mixed).map(&:reason))
          .to eq(["high-entropy token", "openai-style api key"])
        expect(detect(mixed).map(&:start)).to eq([0, mixed.byteindex("sk-")])
      end
    end

    context "when one span is matched by several detectors at once" do
      # `API_KEY=sk-...` is a dotenv assignment, an openai-style key, a
      # credential assignment and a high-entropy run. One secret is one region.
      let(:content) { "API_KEY=sk-#{secret}\n" }

      it "reports one region, not one per detector" do
        expect(detect(content).size).to eq(1)
      end

      it "prefers the issuer-fixed name over the syntactic one" do
        expect(detect(content).first.reason).to eq("openai-style api key")
      end

      context "when the value is quoted and two shapes reach it" do
        let(:quoted) { %(token:"sk-abcdefghijklmnopqrst"\n) }

        it "still takes the name of the higher-precedence shape" do
          expect(detect(quoted).map(&:reason)).to eq(["openai-style api key"])
        end

        it "excludes the quotes from the merged span" do
          expect(detect(quoted).first.bytes).to eq("sk-abcdefghijklmnopqrst")
        end
      end

      # The precedence rule is only OBSERVABLE when the better-named shape starts
      # at a different byte, and excluding quotes collapsed the fixture that used
      # to provide that -- both candidates now begin together, so the example
      # above passes whether or not precedence is applied. `$` restores the offset
      # without a quote: `credential assignment` takes the whole value from `$`,
      # and `sk-` matches one byte later because `$` is neither `\w` nor `-` and
      # so does not trip the issuer shape's lookbehind.
      context "when the better-named shape starts LATER, with no quote involved" do
        let(:unquoted) { "token:$sk-abcdefghijklmnopqrst\n" }

        it "takes the name of the higher-precedence shape, not the earlier one" do
          expect(detect(unquoted).map(&:reason)).to eq(["openai-style api key"])
        end

        it "still spans from the earlier candidate's start" do
          expect(detect(unquoted).first.bytes).to eq("$sk-abcdefghijklmnopqrst")
        end
      end

      # Offsets are what T15 masks by, so the fold's geometry needs pinning at the
      # byte, not merely "one region came out".
      # `$` and `!` are both outside the entropy scanner's charset, so the
      # pattern's value span begins one byte EARLIER and ends one byte LATER than
      # the entropy run inside it. That makes the two ends independently
      # observable: a merge that took the later start, or the earlier finish,
      # changes the bytes.
      context "when two overlapping candidates begin and end at different offsets" do
        let(:content) { "AUTH_TOKEN=$#{secret}!\n" }

        it "reports one region spanning both" do
          expect(detect(content).map(&:bytes)).to eq(["$#{secret}!"])
        end

        it "takes the earlier start and the later finish" do
          region = detect(content).first

          expect(region.start).to eq(content.byteindex("$"))
          expect(region.start + region.length).to eq(content.byteindex("\n"))
        end
      end
    end

    # `String#b` returns a NEW, MUTABLE String, so `frozen_string_literal` does
    # not reach a constant built with it -- which is how `BOM` was born mutable.
    it "freezes its String constants" do
      strings = described_class.constants.map { described_class.const_get(_1) }.grep(String)

      expect(strings).not_to be_empty
      expect(strings).to all(be_frozen)
    end

    it "returns a deeply frozen set" do
      regions = detect("API_KEY=#{secret}\n")

      expect(regions).to be_frozen
      expect(regions).to all(be_frozen)
      expect(regions.map(&:bytes)).to all(be_frozen)
    end
  end

  describe Lain::Sensitivity::Regions::Region do
    def region(bytes) = described_class.new(start: 0, bytes:, reason: "dotenv assignment", detector: :pattern)

    context "when two regions differ only by a backslash escape" do
      # Raw bytes, never routed through `Canonical.digest`: a JSON-native
      # canonicalization normalizes away exactly the difference the key exists
      # to keep. `review/hunk.rb:10-14` settles the identical question.
      let(:escaped) { region('value="a\\nb"') }
      let(:literal) { region(%(value="a\nb")) }

      it "digests them differently" do
        expect(escaped.digest).not_to eq(literal.digest)
      end
    end

    # The escaped/literal pair above differs in LENGTH as well as in content, so
    # on its own it cannot tell a digest of the bytes from a digest of the byte
    # count. This pair is the same length and different bytes.
    it "digests two same-length, different-byte regions differently" do
      expect(region("sk-aaaaaaaaaaaaaaaaaaaa").digest).not_to eq(region("sk-aaaaaaaaaaaaaaaaaaab").digest)
    end

    it "digests bytes that JSON cannot encode" do
      expect { region("\xC3\x28\xFF".b).digest }.not_to raise_error
    end

    # The framing is what keeps a region's address in its own namespace. Without
    # the scheme word a region digest IS a snapshot blob digest of the same bytes;
    # without any framing it is the bare hash every unframed hasher produces. Both
    # halves are asserted, because dropping either one leaves the other passing.
    it "does not collide with a snapshot blob of the same bytes" do
      bytes = "sk-#{secret}"

      expect(region(bytes).digest).not_to eq(Lain::Workspace::Snapshot::Blob.new(bytes:).digest)
    end

    it "does not collide with the bare hash of the same bytes" do
      bytes = "sk-#{secret}"

      expect(region(bytes).digest).not_to end_with(Lain::Ext.blake3_hex(bytes))
    end

    it "carries the digest algorithm in the digest" do
      expect(region("x").digest).to start_with("#{Lain::Canonical::DIGEST_ALGORITHM}:")
    end

    # A golden vector, and the only assertion that can see the whole framing at
    # once: scheme word, separating space, decimal length, NUL, then the bytes.
    # Every structural mutation is invisible to a start/length assertion --
    # dropping the NUL alone changes 668 digests across this repo and no
    # behavioural example notices. T14 is about to persist these, so the framing
    # is a wire contract from here on and a change to it is a migration, not a
    # refactor. Recompute deliberately if you ever mean to break it.
    it "addresses known bytes to a known digest" do
      expect(described_class.address("hunter2".b))
        .to eq("blake3:f1010ca332b93af2b0570d5715aca66d73c63a9ba10207b42641d7e8c9192aa3")
    end

    # T14 caches BY digest and will ask for it in a loop, so it is computed once
    # at construction the way `Snapshot::Blob` does it. Counting the hash calls is
    # the only honest check: `-str` interns, so comparing object identity would
    # pass whether or not anything was memoized.
    it "hashes its bytes exactly once however often the digest is asked for" do
      allow(Lain::Ext).to receive(:blake3_hex).and_call_original

      subject = region("sk-#{secret}")
      3.times { subject.digest }

      expect(Lain::Ext).to have_received(:blake3_hex).once
    end

    # What actually needs pinning about the stored bytes. Asserting that `.b` does
    # not change the digest, or that `length == bytesize`, is true of every String
    # by construction and cannot fail -- these can.
    it "stores its bytes as frozen BINARY whatever encoding they arrive in" do
      stored = region("héllo").bytes

      expect(stored.encoding).to eq(Encoding::BINARY)
      expect(stored).to be_frozen
      expect(stored.bytesize).to eq(6)
    end

    # A region's bytes are the one thing that must never reach a log or the
    # NDJSON Journal by accident; `spec/output_discipline_spec.rb` exists because
    # one stray byte in that stream was a real incident.
    it "withholds its bytes from inspect and to_s" do
      bytes = "sk-#{secret}"
      subject = region(bytes)

      expect(subject.inspect).not_to include(bytes)
      expect(subject.to_s).not_to include(bytes)
      expect(subject.inspect).to include("dotenv assignment")
    end

    # `Ext.blake3_hex` is not ractor-safe -- the same recorded gap
    # `review/hunk.rb:17` pins for Hunk. Digesting eagerly moves that constraint
    # from every READ of the digest to the single CONSTRUCTION, which is the
    # whole benefit: a Region can now be handed to another Ractor and still
    # answer for its own identity. Both halves are pinned, because the useful one
    # is the half that now works.
    describe "Ractor usability" do
      it "is shareable" do
        expect(Ractor.shareable?(region("sk-#{secret}"))).to be(true)
      end

      it "answers for its digest off the main Ractor" do
        subject = region("sk-#{secret}")

        expect(Ractor.new(subject, &:digest).value).to eq(subject.digest)
      end

      it "can only be constructed on the main Ractor" do
        expect { Ractor.new { described_class.new(start: 0, bytes: "sk-x", reason: "r", detector: :pattern) }.value }
          .to raise_error(Ractor::RemoteError)
      end
    end
  end
end
