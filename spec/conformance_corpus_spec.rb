# frozen_string_literal: true

require "tmpdir"
require_relative "conformance/corpus_generator"

# The Ruby half of the frozen conformance corpus (ext/lain/corpus): the corpus files are the ones the manifest
# names, the canonical vectors regenerate byte for byte and re-derive from Ruby, and the compiled extension
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
    when "role" then Lain::Ext::Event.new(role: tagged.decode(input.fetch("role")), content: [])
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

  it "generates every file its manifest names" do
    expect(described_class::FILES.map { "#{_1}.ndjson" }).to match_array(described_class.recorded.fetch("files").keys)
  end

  it "records the commit at which the dag, store, event and errors vectors stopped re-deriving from Ruby" do
    retired = described_class.recorded.fetch("ruby_oracle_retired")
    expect(retired.fetch("sha")).to match(/\A\h{40}\z/)
    expect(retired.fetch("vectors")).to contain_exactly("dag", "store", "event_digest", "errors")
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

  # Only Canonical still has a Ruby implementation to answer from; the other
  # files' Ruby is gone, and the manifest's digests are what hold them still.
  it "regenerates the canonical vectors byte for byte from the manifest's seed" do
    regenerated = described_class.in_utf8 { described_class.vectors("canonical", described_class.recorded_seed) }
    expect(regenerated).to eq(described_class.read(described_class.path("canonical")))
  end

  it "re-derives every canonical vector from the Ruby implementation" do
    expect(described_class.underived("canonical")).to be_empty
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

  describe "the regions vectors" do
    let(:records) { described_class.records("regions").map(&:first) }
    let(:shapes) { described_class::RegionVectors.shapes }

    def of_kind(group, kind) = group.select { |record| record.dig("input", "label") == kind }

    def labelled(label) = records.select { _1.dig("input", "label") == label }

    it "covers the 20 content shapes and the 5 other shapes Regions scans" do
      expect(shapes.keys).to include(*Lain::Sensitivity::Regions::CONTENT_SHAPES.keys)
      expect(shapes.keys).to include("TOKEN", "PEM_PUBLIC", "OPENSSH_PUBLIC", "CHECKSUM_FIELD", "INTEGRITY_FIELD")
      expect(shapes.size).to eq(25)
    end

    it "gives every shape a positive the Ruby regex matches and a near-miss it does not" do
      by_shape = records.group_by { _1.dig("input", "shape") }
      expect(by_shape.keys).to include(*shapes.keys)
      shapes.each_key do |name|
        positives = of_kind(by_shape.fetch(name), "positive")
        misses = of_kind(by_shape.fetch(name), "near_miss")
        expect(positives).not_to be_empty, name
        expect(misses).not_to be_empty, name
        expect(positives.map { _1.dig("output", "matches") }).to all(be_any), name
        expect(misses.map { _1.dig("output", "matches") }).to all(be_empty), name
      end
    end

    it "reproduces every recorded range from the Ruby regex" do
      expect(described_class.underived("regions")).to be_empty
    end

    it "regenerates byte for byte" do
      regenerated = described_class.in_utf8 { described_class.vectors("regions", described_class.recorded_seed) }
      expect(regenerated).to eq(described_class.read(described_class.path("regions")))
    end

    it "records group 0 and every named group, and the last repeated group that took part for netrc" do
      password_first = records.find { _1.dig("input", "label") == "netrc password first" }
      text = [password_first.dig("input", "bytes")].pack("H*")
      match = password_first.dig("output", "matches").first
      expect(match.keys).to contain_exactly("0", "value")
      expect(text.byteslice(*match.fetch("value").then { |from, to| [from, to - from] })).to eq("s3cretpw")
    end

    it "keeps a BOM text, invalid UTF-8 and UTF-16, offsets indexing the bytes handed over" do
      bom, bad, wide = %w[bom invalid_utf8 utf16].map { labelled(_1).first }
      expect([bom, bad, wide]).to all(be_truthy)
      expect(bom.dig("output", "skip")).to eq(3)
      expect([bad.dig("input", "bytes")].pack("H*").dup.force_encoding(Encoding::UTF_8)).not_to be_valid_encoding
      expect([wide.dig("input", "bytes")].pack("H*").start_with?("\xFF\xFE".b)).to be(true)
    end

    it "carries matches from both spike corpora" do
      expect(labelled("spike lib and docs")).not_to be_empty
      expect(labelled("spike specs and fixtures")).not_to be_empty
    end
  end
end
