# frozen_string_literal: true

# `$INPUT_RECORD_SEPARATOR` is only an alias of `$/` once English is loaded --
# without it the assignment below would set an unrelated global and the example
# would pass vacuously.
require "English"

# Lain::Structural::Matcher is THE single Ruby seam over Lain::Ext::AstGrep
# (T1): no other unit calls the ext directly, so it alone would need to change
# on a breaking ext bump. It owns byte -> 1-based line conversion and the
# supported-language allowlist -- both deliberately absent from the ext's own
# byte-offsets-only contract (see ext/lain/src/astgrep.rs's module doc).
RSpec.describe Lain::Structural::Matcher do
  subject(:matcher) { described_class.new }

  describe "#match" do
    it "returns one domain Match per structural hit, with a byte range and named captures" do
      matches = matcher.match(source: "def total(x)\n  x\nend", language: :ruby, pattern: "def $NAME($$$A)")

      expect(matches.size).to eq(1)
      match = matches.first
      expect(match.byte_range).to eq(0...(match.byte_range.end))
      expect(match.byte_range).to be_a(Range)
      expect(match.captures).to eq("NAME" => "total")
    end

    it "computes a 1-based line by counting newlines in the byte prefix, not trusting the ext's own line" do
      source = "# leading comment\n# second comment\ndef total(x)\n  x\nend"

      matches = matcher.match(source:, language: :ruby, pattern: "def $NAME($$$A)")

      expect(matches.first.line).to eq(3)
    end

    it "derives every match's line from ONE pass over the source, never a per-match byte prefix" do
      source = +(["record.save"] * 50).join("\n")

      # The old derivation walked the source once PER MATCH -- O(matches x source).
      # `.b` is that one pass, so `once` is the whole claim; asserting no
      # `byteslice` would not be, since a per-match slice of the `.b` COPY is
      # invisible from here.
      expect(source).to receive(:b).once.and_call_original

      expect(matcher.match(source:, language: :ruby, pattern: "$RECV.save").size).to eq(50)
    end

    it "agrees with the byte-prefix newline count on every match, across many lines" do
      source = (1..50).map { |i| "record.save # #{i}\n" }.join

      matches = matcher.match(source:, language: :ruby, pattern: "$RECV.save")

      expect(matches.map(&:line))
        .to eq(matches.map { |m| source.byteslice(0, m.byte_range.begin).b.count("\n") + 1 })
        .and eq((1..50).to_a)
    end

    it "counts newline BYTES, so a multi-byte character before a match never shifts its line" do
      source = "# ✨ sparkle\n# ✨ again\nrecord.save\n"

      expect(matcher.match(source:, language: :ruby, pattern: "$RECV.save").first.line).to eq(3)
    end

    it "counts newline BYTES, so a caller's $/ cannot move a match onto another line" do
      # `each_line` honours `$/`; the byte-prefix `count("\n")` this replaced did
      # not. A caller that sets `$/` must not silently re-number every match.
      # The `|` has to come BEFORE the matched lines: under `$/ = "|"` the first
      # chunk swallows a real newline, and every line number after it shifts.
      source = "x = 1|2\nrecord.save\nrecord.save\n"

      begin
        $INPUT_RECORD_SEPARATOR = "|"
        expect(matcher.match(source:, language: :ruby, pattern: "$RECV.save").map(&:line)).to eq([2, 3])
      ensure
        $INPUT_RECORD_SEPARATOR = "\n"
      end
    end

    it "returns [] for a valid pattern with no matches" do
      expect(matcher.match(source: "x = 1", language: :ruby, pattern: "$RECV.save")).to eq([])
    end

    it "matches structure, so `save` inside a comment or a string never counts" do
      src = <<~RUBY
        # remember to record.save the row
        note = "call record.save when ready"
        record.save
      RUBY

      matches = matcher.match(source: src, language: :ruby, pattern: "$RECV.save")

      expect(matches.size).to eq(1)
      expect(matches.first.captures).to eq("RECV" => "record")
    end

    it "returns deeply frozen Match value objects" do
      matches = matcher.match(source: "def total(x)\n  x\nend", language: :ruby, pattern: "def $NAME($$$A)")

      expect(matches.first).to be_deeply_frozen
    end

    it "wraps a malformed pattern in its OWN typed error, insulating the ext's BadPattern" do
      expect(Lain::Structural::Matcher::BadPattern.ancestors).to include(Lain::Error)

      expect { matcher.match(source: "x = 1", language: :ruby, pattern: "def (") }
        .to raise_error(Lain::Structural::Matcher::BadPattern)
    end

    it "never lets the ext's own BadPattern escape uncaught" do
      error = begin
        matcher.match(source: "x = 1", language: :ruby, pattern: "def (")
      rescue StandardError => e
        e
      end

      expect(error).to be_a(Lain::Structural::Matcher::BadPattern)
      expect(error).not_to be_a(Lain::Ext::AstGrep::BadPattern)
    end

    it "rejects an unsupported language before ever calling the ext, naming the language" do
      expect(Lain::Ext::AstGrep).not_to receive(:search)

      expect { matcher.match(source: "x = 1", language: :cobol, pattern: "$A") }
        .to raise_error(Lain::Structural::Matcher::UnknownLanguage, /cobol/)
    end
  end

  describe "#dump" do
    it "delegates to the ext and reveals the singleton_method node distinct from a plain method" do
      dumped = matcher.dump(source: "def self.x; end", language: :ruby)

      expect(dumped).to include("singleton_method")
    end

    it "rejects an unsupported language before ever calling the ext, naming the language" do
      expect(Lain::Ext::AstGrep).not_to receive(:dump)

      expect { matcher.dump(source: "x = 1", language: :cobol) }
        .to raise_error(Lain::Structural::Matcher::UnknownLanguage, /cobol/)
    end

    # 4 KB of nesting dumped to 12 MB before the ext grew a bound: the per-node
    # indent alone is quadratic in depth.
    context "with a source nested past the ext's depth cap" do
      let(:nested) { "#{"(" * 2000}1#{")" * 2000}" }

      it "refuses with this seam's OWN typed error, naming the cap" do
        expect { matcher.dump(source: nested, language: :ruby) }
          .to raise_error(Lain::Structural::Matcher::DumpCapped, /capped at/)
      end

      it "raises an error a `rescue Lain::Error` site catches -- never a bare Ruby builtin" do
        # Every Ext error subclasses Lain::Error for one reason: an error outside
        # that tree is a class none of Lain's `rescue Lain::Error` sites catch
        # (see spec/lain/rust/store_spec.rb). The depth refusal crosses the FFI
        # boundary AS this class, so it inherits that guarantee.
        expect(Lain::Structural::Matcher::DumpCapped.ancestors).to include(Lain::Error)

        error = begin
          matcher.dump(source: nested, language: :ruby)
        rescue StandardError => e
          e
        end

        expect(error).to be_a(Lain::Error)
        expect(error).not_to be_a(RangeError)
      end
    end

    it "never launders an unrelated ext failure into DumpCapped" do
      # Mapping the refusal by RESCUING A RUBY BUILTIN made every RangeError out
      # of the ext -- e.g. "bignum too big to convert into 'long'" -- reach the
      # model as a DumpCapped naming no cap at all.
      allow(Lain::Ext::AstGrep).to receive(:dump).and_raise(RangeError, "bignum too big to convert into 'long'")

      expect { matcher.dump(source: "x = 1", language: :ruby) }
        .to raise_error(RangeError, /bignum/)
    end

    it "truncates a dump past the OUTPUT cap and discloses it, rather than refusing outright" do
      dumped = matcher.dump(source: "x = 1\n" * 20_000, language: :ruby)

      expect(dumped).to start_with("program\n")
      expect(dumped).to end_with("... capped at 65536 bytes\n")
    end
  end
end
