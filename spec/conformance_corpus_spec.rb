# frozen_string_literal: true

require "tmpdir"
require_relative "conformance/corpus_generator"

# The Ruby half of the frozen conformance corpus (ext/lain/corpus): the corpus files are the ones the manifest
# names, they regenerate byte for byte, every vector still re-derives from Ruby, and the compiled extension
# answers every canonical and error vector as the corpus says it must. The generator is
# spec/conformance/corpus_generator.rb; ext/lain/src/corpus.rs reads the same files under `cargo test`.
RSpec.describe ConformanceCorpus do
  let(:tagged) { described_class::Tagged }

  def round_trip(value) = tagged.decode(JSON.parse(JSON.generate(tagged.encode(value))))

  def refusal
    yield
    :accepted
  rescue StandardError => e
    [e.class.name, e.message]
  end

  def through_extension(input)
    case input.fetch("case")
    when "canonical" then Lain::Ext.canonical_dump(tagged.decode(input.fetch("value")))
    when "role" then Lain::Ext::Turn.new(role: tagged.decode(input.fetch("role")), content: [])
    when "kind" then Lain::Ext::Event.new(kind: tagged.decode(input.fetch("kind")), body: {})
    else Lain::Ext::Store.new.fetch(input.fetch("digest"))
    end
  end

  it "loses nothing the corpus records through its tagged encoding" do
    nan_payload = ["7ff8000000000123"].pack("H*").unpack1("G")
    values = [:sym, "\xff".b, (+"a\xffb").force_encoding(Encoding::UTF_8), Float::NAN, nan_payload, -0.0, 0.0,
              Float::INFINITY, { :a => 1, "b" => [:c, "c"], :"é" => -0.0 }, 2**70, -(2**70), "\u0000 "]
    values.each { |value| expect(tagged.identical?(round_trip(value), value)).to be(true), value.inspect }
    expect(round_trip({ a: 1, "a" => 2 }).keys).to eq([:a, "a"])
    expect(tagged.identical?(-0.0, 0.0)).to be(false)
  end

  it "holds every corpus file at the digest its manifest records" do
    expect(described_class.tampered(described_class::DIR)).to be_empty
  end

  it "refuses a corpus file with one byte changed, naming the file and its expected digest" do
    Dir.mktmpdir("corpus") do |dir|
      FileUtils.cp_r("#{described_class::DIR}/.", dir)
      target = File.join(dir, "store.ndjson")
      bytes = File.binread(target)
      bytes.setbyte(10, bytes.getbyte(10) ^ 1)
      File.binwrite(target, bytes)
      expected = JSON.parse(File.read(File.join(dir, "MANIFEST.json"))).dig("files", "store.ndjson", "blake3")
      expect(described_class.tampered(dir))
        .to contain_exactly(a_string_starting_with("store.ndjson: expected #{expected}"))
    end
  end

  it "regenerates every file and the manifest byte for byte from the manifest's seed and sha" do
    regenerated = described_class.generate(seed: described_class.recorded_seed, sha: described_class.recorded_sha)
    changed = regenerated.reject { |file, text| described_class.read(File.join(described_class::DIR, file)) == text }
    expect(regenerated.keys).to include("MANIFEST.json")
    expect(changed.keys).to be_empty
  end

  it "re-derives every vector from the Ruby implementation" do
    expect(described_class::FILES.flat_map { described_class.underived(_1) }).to be_empty
  end

  it "answers every canonical vector through the compiled extension as Ruby did" do
    wrong = described_class.records("canonical").filter_map do |record, at|
      value = tagged.decode(record.dig("input", "value"))
      answer = [Lain::Ext.canonical_dump(value), Lain::Ext.canonical_digest(value)]
      at unless answer == record.fetch("output").values_at("dump", "digest")
    end
    expect(wrong).to be_empty
  end

  it "refuses every error vector through the compiled extension as the corpus says it must" do
    wrong = described_class.in_utf8 do
      described_class.records("errors").filter_map do |record, at|
        expected = described_class.extension_refusal(record.dig("output", "raised"))
        answer = refusal { through_extension(record.fetch("input")) }
        "#{at}: #{answer.inspect}, wanted #{expected.inspect}" unless answer == expected
      end
    end
    expect(wrong).to be_empty
  end
end
