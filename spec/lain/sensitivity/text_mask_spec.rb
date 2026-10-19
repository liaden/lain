# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::TextMask do
  let(:secret) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }
  let(:other) { "Zq9wX3eC7rV1tB5yN8uM2iO6pL4aS0dF3gH7jK1lQ5wE9rT2" }
  let(:mask) { described_class.new(secrets: []) }
  let(:key) { OpenSSL::PKey::RSA.new(1024).to_pem }

  def placeholder(ordinal) = format(Lain::Sensitivity::Regions::PLACEHOLDER, ordinal)

  def streamed(stream, chunks) = chunks.map { stream << _1 }.join + stream.finish

  describe "#call" do
    it "returns the masked text and the count, numbering from 1" do
      text = "A_TOKEN=#{secret}\nB_TOKEN=#{other}\n"

      expect(mask.call(text)).to eq(["A_TOKEN=#{placeholder(1)}\nB_TOKEN=#{placeholder(2)}\n", 2])
    end

    it "masks a given secret wherever it recurs" do
      masked, count = described_class.new(secrets: [other]).call("echo #{other} #{other}\n")

      expect([masked, count]).to eq(["echo #{placeholder(1)} #{placeholder(2)}\n", 2])
    end

    it "leaves clean text alone" do
      expect(mask.call("hello\n")).to eq(["hello\n", 0])
    end
  end

  describe "#stream" do
    it "numbers as the whole text does, with chunks split mid-secret" do
      text = "A_TOKEN=#{secret}\nB_TOKEN=#{other}\n"
      chunks = [text[0, 20], text[20, 30], text[50..]]

      expect(streamed(mask.stream, chunks)).to eq(mask.call(text).first)
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

    it "keeps counting across chunks" do
      stream = mask.stream
      streamed(stream, ["A_TOKEN=#{secret}\n", "B_TOKEN=#{other}\n"])

      expect(stream.count).to eq(2)
    end
  end
end
