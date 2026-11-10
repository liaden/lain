# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::TextMask do
  let(:secret) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }
  let(:other) { "Zq9wX3eC7rV1tB5yN8uM2iO6pL4aS0dF3gH7jK1lQ5wE9rT2" }
  let(:mask) { described_class.new(secrets: []) }
  let(:key) { OpenSSL::PKey::RSA.new(1024).to_pem }

  def placeholder(ordinal) = format(Lain::Sensitivity::Regions::PLACEHOLDER, ordinal)

  def streamed(stream, chunks) = chunks.map { stream << _1 }.join + stream.finish

  describe ".text" do
    it "masks as the instance does" do
      text = "A_TOKEN=#{secret}\necho #{other}\n"

      expect(described_class.text(text, secrets: [other])).to eq(described_class.new(secrets: [other]).call(text).text)
    end

    it "takes any secrets that answer to_a" do
      expect(described_class.text("echo #{other}\n", secrets: Set[other])).to eq("echo #{placeholder(1)}\n")
    end
  end

  describe "#call" do
    it "returns the masked text and the fresh count, numbering from 1" do
      text = "A_TOKEN=#{secret}\nB_TOKEN=#{other}\n"

      expect(mask.call(text))
        .to eq(Lain::Sensitivity::Masked.new(text: "A_TOKEN=#{placeholder(1)}\nB_TOKEN=#{placeholder(2)}\n", fresh: 2,
                                             prior: 0))
    end

    it "masks a given secret wherever it recurs" do
      masked = described_class.new(secrets: [other]).call("echo #{other} #{other}\n")

      expect(masked).to have_attributes(text: "echo #{placeholder(1)} #{placeholder(2)}\n", fresh: 2)
    end

    it "shows a region whose digest is released, and masks the rest" do
      digest = Lain::Sensitivity::Regions.detect("A_TOKEN=#{secret}\n").first.digest
      masked = described_class.new(secrets: [], released: Set[digest]).call("A_TOKEN=#{secret}\nB_TOKEN=#{other}\n")

      expect(masked).to have_attributes(text: "A_TOKEN=#{secret}\nB_TOKEN=#{placeholder(1)}\n", fresh: 1)
    end

    it "masks a released region's bytes where a secret-named value holds them too" do
      digest = Lain::Sensitivity::Regions.detect("A_TOKEN=#{secret}\n").first.digest

      expect(described_class.new(secrets: [secret], released: Set[digest]).call("A_TOKEN=#{secret}\n").text)
        .to eq("A_TOKEN=#{placeholder(1)}\n")
    end

    it "leaves clean text alone" do
      expect(mask.call("hello\n")).to eq(Lain::Sensitivity::Masked.new(text: "hello\n", fresh: 0, prior: 0))
    end

    it "counts a placeholder already present as prior, not fresh, and keeps its number" do
      text = "seen #{placeholder(3)}\nA_TOKEN=#{secret}\n"

      expect(mask.call(text))
        .to eq(Lain::Sensitivity::Masked.new(text: "seen #{placeholder(3)}\nA_TOKEN=#{placeholder(4)}\n", fresh: 1,
                                             prior: 1))
    end

    it "numbers after the highest placeholder present when one repeats" do
      text = "#{placeholder(2)} #{placeholder(2)} #{placeholder(1)}\nA_TOKEN=#{secret}\n"

      expect(mask.call(text).text).to end_with("A_TOKEN=#{placeholder(3)}\n")
    end

    it "does not mask a placeholder a secret-named key holds" do
      text = %("password": "#{placeholder(1)}"\napi_token: #{placeholder(2)}\n)

      expect(mask.call(text)).to eq(Lain::Sensitivity::Masked.new(text:, fresh: 0, prior: 2))
    end

    it "never lets a given secret eat a placeholder it spells part of" do
      text = "#{placeholder(1)} redacted\n"

      expect(described_class.new(secrets: ["redacted"]).call(text).text).to eq("#{placeholder(1)} #{placeholder(2)}\n")
    end

    context "with UTF-16 text" do
      let(:aws) { "AKIAQZ7R2M4X9TBL3KWE" }
      let(:bytes) { "\xFF\xFE".b + "user=lain\nAWS=#{aws}\n".encode(Encoding::UTF_16LE).b }

      it "masks a key and keeps the text legible as UTF-16LE" do
        text = mask.call(bytes).text

        expect(text.b).to eq("\xFF\xFE".b + "user=lain\nAWS=#{placeholder(1)}\n".encode(Encoding::UTF_16LE).b)
      end

      it "changes no byte when it masks masked text again" do
        once = mask.call(bytes).text

        expect(mask.call(once)).to have_attributes(text: once, fresh: 0, prior: 1)
      end
    end

    describe "its laws, over drawn texts" do
      let(:word) { PropCheck::Generators.alphanumeric_string(min: 1, max: 8) }
      let(:token) { PropCheck::Generators.alphanumeric_string(min: 40, max: 48).map { "kJ8fQ#{_1}Zq9" } }
      let(:holder) { PropCheck::Generators.choose(1..9).map { placeholder(_1) } }
      let(:line) do
        piece = PropCheck::Generators.one_of(word, token.map { "A_TOKEN=#{_1}" }, holder)
        PropCheck::Generators.array(piece, min: 1, max: 4).map { "#{_1.join(" ")}\n" }
      end
      let(:drawn) { PropCheck::Generators.array(line, min: 1, max: 5).map(&:join) }

      def placeholders_in(text) = text.scan(/<redacted:\d+>/)

      it "is idempotent: a second pass changes no byte, finds nothing fresh and counts what is there",
         aggregate_failures: false do
        forall(text: drawn) do |text:|
          once = mask.call(text)

          expect(mask.call(once.text))
            .to eq(Lain::Sensitivity::Masked.new(text: once.text, fresh: 0, prior: once.fresh + once.prior))
        end
      end

      it "is extensive: no placeholder disappears, and each fresh region adds one", aggregate_failures: false do
        forall(text: drawn) do |text:|
          masked = mask.call(text)

          expect(placeholders_in(masked.text).size).to eq(placeholders_in(text).size + masked.fresh)
        end
      end
    end
  end

  describe "#stream" do
    it "numbers as the whole text does, with chunks split mid-secret" do
      text = "A_TOKEN=#{secret}\nB_TOKEN=#{other}\n"
      chunks = [text[0, 20], text[20, 30], text[50..]]

      expect(streamed(mask.stream, chunks)).to eq(mask.call(text).text)
    end

    it "never reuses a placeholder slot a previous chunk showed" do
      stream = mask.stream

      expect(streamed(stream, ["#{placeholder(1)}\n", "A_TOKEN=#{secret}\n"]))
        .to eq("#{placeholder(1)}\nA_TOKEN=#{placeholder(2)}\n")
    end

    it "numbers a later fresh region past the highest placeholder in the same chunk" do
      text = "a #{placeholder(3)} b\nA_TOKEN=#{secret}\n"

      expect(streamed(mask.stream, [text])).to eq(mask.call(text).text)
    end

    it "masks the same bytes however the input is split", aggregate_failures: false do
      text = "A_TOKEN=#{secret}\nplain line\nB_TOKEN=#{other}\ntail"
      cuts = PropCheck::Generators.array(PropCheck::Generators.choose(0..text.size), min: 0, max: 6).map(&:sort)

      forall(cuts:) do |cuts:|
        chunks = [0, *cuts, text.size].each_cons(2).map { |from, to| text[from...to] }

        expect(streamed(mask.stream, chunks)).to eq(mask.call(text).text)
      end
    end

    it "masks the same bytes however a text opening with a placeholder is split", aggregate_failures: false do
      text = "plain #{placeholder(2)}\nA_TOKEN=#{secret}\nB_TOKEN=#{other}\ntail"
      cuts = PropCheck::Generators.array(PropCheck::Generators.choose(0..text.size), min: 0, max: 6).map(&:sort)

      forall(cuts:) do |cuts:|
        chunks = [0, *cuts, text.size].each_cons(2).map { |from, to| text[from...to] }

        expect(streamed(mask.stream, chunks)).to eq(streamed(mask.stream, [text]))
      end
    end

    it "emits only complete lines" do
      stream = mask.stream

      expect([stream << "partial", stream << " line\nrest"]).to eq(["", "partial line\n"])
    end

    it "emits nothing of a key until its END line arrives, then the key masked as one region" do
      lines = key.lines
      stream = mask.stream
      early = stream << "before\n#{lines[..-2].join}"
      closed = stream << "#{lines.last}after\n"

      expect([early, closed]).to eq(["before\n", "#{placeholder(1)}\nafter\n"])
    end

    it "never releases an unterminated key raw" do
      stream = mask.stream
      out = (stream << key.lines[..-2].join) + stream.finish

      expect(out).not_to include(key.lines[1].chomp)
    end

    it "masks the held key once the hold passes the cap, then drops its later lines through END" do
      stream = mask.stream
      body = "A" * (described_class::Stream::HOLD_CAP + 1)
      capped = stream << "-----BEGIN PRIVATE KEY-----\n#{body}\n"
      later = stream << "LATERLINE\n-----END PRIVATE KEY-----\ntrailing\n"

      expect([capped, later]).to eq([placeholder(1), "trailing\n"])
    end

    it "counts a key masked at the cap and the secret after it" do
      stream = mask.stream
      streamed(stream, ["-----BEGIN PRIVATE KEY-----\n#{"A" * (described_class::Stream::HOLD_CAP + 1)}\n",
                        "-----END PRIVATE KEY-----\nA_TOKEN=#{secret}\n"])

      expect(stream.count).to eq(2)
    end

    it "emits each carriage-return progress frame once the next one begins" do
      stream = mask.stream
      frames = Array.new(5) { |step| "\r#{step * 20}% [#{"=" * step}]" }

      expect(frames.map { stream << _1 } + [stream.finish])
        .to eq(["\r", "0% []\r", "20% [=]\r", "40% [==]\r", "60% [===]\r", "80% [====]"])
    end

    it "emits a partial line once it passes the partial cap" do
      expect((mask.stream << ("x" * 400_000)).bytesize).to eq(400_000)
    end

    it "cuts a partial line at its last space, so a token there is masked whole" do
      stream = mask.stream
      words = "word " * 1000

      expect([stream << "#{words}A_TOKEN=#{secret}", stream.finish]).to eq([words, "A_TOKEN=#{placeholder(1)}"])
    end

    it "holds a key block past the partial cap, under its own hold cap" do
      stream = mask.stream
      held = [stream << "-----BEGIN PRIVATE KEY-----\n", stream << ("A" * 10_000)]

      expect([held, stream.finish]).to eq([["", ""], placeholder(1)])
    end

    it "draws placeholders from a numbering it shares with another stream" do
      ordinals = (1..).each
      stdout, stderr = Array.new(2) { mask.stream(ordinals:) }

      expect([stdout << "A_TOKEN=#{secret}\n", stderr << "B_TOKEN=#{other}\n", stdout << "C_TOKEN=#{other}\n"])
        .to eq(["A_TOKEN=#{placeholder(1)}\n", "B_TOKEN=#{placeholder(2)}\n", "C_TOKEN=#{placeholder(3)}\n"])
    end

    context "with UTF-16LE output" do
      let(:aws) { "AKIAQZ7R2M4X9TBL3KWE" }
      let(:text) { "\xFF\xFE".b + "user=lain\nAWS=#{aws}\ndone\n".encode(Encoding::UTF_16LE).b }

      def legible?(piece) = piece.bytesize.even? && piece.dup.force_encoding(Encoding::UTF_16LE).valid_encoding?

      def pieces_of(cuts) = [0, *cuts, text.bytesize].each_cons(2).map { |from, to| text.byteslice(from...to) }

      it "masks as the whole text does, cut on its 2-byte newlines", aggregate_failures: false do
        cuts = PropCheck::Generators.array(PropCheck::Generators.choose(0..text.bytesize), min: 0, max: 6).map(&:sort)

        forall(cuts:) do |cuts:|
          stream = mask.stream
          shown = pieces_of(cuts).map { stream << _1 } << stream.finish

          expect(shown).to all(satisfy { legible?(_1) })
          expect(shown.join.b).to eq(mask.call(text).text.b)
        end
      end

      it "cuts a long partial line at a 2-byte blank" do
        words = "word " * 1000
        stream = mask.stream
        line = "\xFF\xFE".b + "#{words}AWS=#{aws}".encode(Encoding::UTF_16LE).b

        expect([stream << line, stream.finish].map { _1.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8) })
          .to eq(["\uFEFF#{words}", "AWS=#{placeholder(1)}"])
      end

      def shown_by(pieces)
        stream = mask.stream
        (pieces.map { stream << _1 } << stream.finish).reject(&:empty?)
      end

      def leaked?(shown) = shown.join.b.then { _1.include?(aws.encode(Encoding::UTF_16LE).b) || _1.include?(aws) }

      it "masks a key in a later piece too CJK-heavy to read as UTF-16 alone" do
        shown = shown_by(["\xFF\xFE".b + "ok\n".encode(Encoding::UTF_16LE).b,
                          "#{"日本語" * 30}#{aws}\n".encode(Encoding::UTF_16LE).b])

        expect([leaked?(shown), shown.all? { legible?(_1) }]).to eq([false, true])
      end

      it "never cuts on newline bytes that sit across 2 units" do
        shown = shown_by(["\xFF\xFE".b + "x\u0A0A\u0100y".encode(Encoding::UTF_16LE).b,
                          "AWS=#{aws}\n".encode(Encoding::UTF_16LE).b])

        expect([leaked?(shown), shown.all? { legible?(_1) }]).to eq([false, true])
      end

      it "keeps a long line with no blank legible when it arrives in odd-sized chunks" do
        long = "\xFF\xFE".b + "#{"z" * 5000}AWS=#{aws}\n".encode(Encoding::UTF_16LE).b
        shown = shown_by(long.bytes.each_slice(4097).map { _1.pack("C*") })

        expect([leaked?(shown), shown.all? { legible?(_1) }]).to eq([false, true])
      end

      it "shows no key text through the live display, and every piece decodes as UTF-16LE" do
        channel = RecordingChannel.new
        secrets = Lain::Sensitivity::Secrets::Source.new(child_env: Lain::Exec::ChildEnv.new(env: {}),
                                                         history: Lain::Sensitivity::HistoryLiterals::Null)
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: nil, channel:)
        sink = Lain::Sensitivity::Display.new(secrets:).sinks(invocation).fetch(:stdout_sink)
        text.bytes.each_slice(3) { sink << _1.pack("C*") }
        sink.flush
        shown = channel.events.map(&:bytes).reject(&:empty?)

        expect(shown).to all(satisfy { legible?(_1) })
        expect(shown.join.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8))
          .to eq("\uFEFFuser=lain\nAWS=#{placeholder(1)}\ndone\n")
      end
    end

    it "keeps counting across chunks" do
      stream = mask.stream
      streamed(stream, ["A_TOKEN=#{secret}\n", "B_TOKEN=#{other}\n"])

      expect(stream.count).to eq(2)
    end
  end
end
