# frozen_string_literal: true

require "json"

# Shannon entropy and the alphabet-run test, computed in Rust. The frozen corpus holds the answers Ruby gave
# before they moved, as IEEE bits, so agreement is exact and not within a tolerance.
RSpec.describe Lain::Ext::Entropy do
  def corpus
    path = File.expand_path("../../../ext/lain/corpus/entropy.ndjson", __dir__)
    File.foreach(path).map { JSON.parse(_1) }
  end

  def token_of(record)
    bytes = [record.dig("input", "token").delete(" ")].pack("H*")
    record.dig("input", "binary") ? bytes.force_encoding(Encoding::BINARY) : bytes.force_encoding(Encoding::UTF_8)
  end

  def bits(float) = [float].pack("G").unpack1("H*")

  it "binds exactly shannon and alphabet_run?" do
    expect(described_class.singleton_methods(false)).to contain_exactly(:shannon, :alphabet_run?)
  end

  it "answers every corpus token with the bits Ruby gave" do
    wrong = corpus.reject { bits(described_class.shannon(token_of(_1))) == _1.dig("output", "shannon") }

    expect([corpus.size.positive?, wrong]).to eq([true, []])
  end

  it "answers every corpus token's alphabet run as Ruby did" do
    wrong = corpus.reject { described_class.alphabet_run?(token_of(_1)) == _1.dig("output", "alphabet_run") }

    expect(wrong).to be_empty
  end

  it "counts characters of a UTF-8 String and bytes of a binary one" do
    token = "éééé"

    expect([described_class.shannon(token), described_class.shannon(token.b)]).to eq([0.0, 1.0])
  end

  it "counts each invalid byte of a UTF-8 String as its own character" do
    expect(described_class.shannon((+"\xE3\x81").force_encoding(Encoding::UTF_8))).to eq(1.0)
  end

  it "is 0 for the empty String" do
    expect(described_class.shannon("")).to eq(0.0)
  end

  it "reads US-ASCII like UTF-8" do
    expect(described_class.shannon((+"abcd").force_encoding(Encoding::US_ASCII))).to eq(2.0)
  end

  # What each_char read before the measure moved: the String's own characters, whatever its encoding.
  {
    "Windows-1252" => ["\xE9\xE9\xE8\xE8", Encoding::Windows_1252, 1.0],
    "EUC-JP" => ["\xA4\xA2\xA4\xA2\xA4\xA4", Encoding::EUC_JP, 0.9182958340544896],
    "UTF-16LE" => ["a\x00b\x00c\x00d\x00", Encoding::UTF_16LE, 2.0],
    "US-ASCII holding high bytes" => ["\xE3\x81\xA4\xE3\x81\xA4", Encoding::US_ASCII, Math.log2(3)],
    "broken EUC-JP" => ["\xA4\xA2\xA4", Encoding::EUC_JP, 1.0]
  }.each do |name, (bytes, encoding, bits)|
    it "counts the characters of a #{name} String as Ruby's each_char reads them" do
      token = (+bytes).force_encoding(encoding)

      expect(described_class.shannon(token)).to be_within(1e-12).of(bits)
    end
  end

  it "refuses a value that is not a String" do
    expect { described_class.alphabet_run?(:abcdefghijklmnop) }.to raise_error(TypeError, /String/)
  end

  it "keeps shannon between 0 and log2 of the distinct characters, whatever the order" do
    random = Random.new(24)
    tokens = Array.new(40) { Array.new(random.rand(1..60)) { random.rand(0x20..0x2ff).chr(Encoding::UTF_8) }.join }
    ok = tokens.all? do |token|
      value = described_class.shannon(token)
      value.between?(0.0, Math.log2(token.chars.uniq.size) + 1e-9) &&
        (described_class.shannon(token.chars.shuffle(random:).join) - value).abs < 1e-9
    end

    expect(ok).to be(true)
  end

  it "is Ractor shareable in what it returns" do
    expect(Ractor.shareable?(described_class.shannon("abc"))).to be(true)
  end
end
