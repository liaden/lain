# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Journal::Line do
  describe ".classify" do
    def classify(line, last: false) = described_class.classify(line, last:)

    it "calls a JSON object a record" do
      expect(classify(%({"type":"turn"}\n))).to eq(:record)
    end

    it "calls an already-parsed Hash a record" do
      expect(classify({ type: "turn" })).to eq(:record)
    end

    it "calls a whitespace-only line blank" do
      expect(classify("  \n")).to eq(:blank)
    end

    it "calls JSON that is not an object another writer's line" do
      expect(classify("[1,2]\n")).to eq(:foreign)
    end

    it "calls a non-String, non-Hash entry foreign" do
      expect(classify(42)).to eq(:foreign)
    end

    it "calls an unparseable last line without its newline the tail" do
      expect(classify(%({"type":"tu), last: true)).to eq(:tail)
    end

    it "calls an unparseable line damage when it is not the last" do
      expect(classify(%({"type":"tu))).to eq(:damage)
    end

    it "calls an unparseable last line damage when it carries its newline" do
      expect(classify(%({"type":"tu\n), last: true)).to eq(:damage)
    end

    it "lets a whole record win over the tail test" do
      expect(classify(%({"type":"turn"}), last: true)).to eq(:record)
    end
  end

  describe ".link" do
    it "names the line's bytes, newline excluded, by their blake3 digest" do
      line = %({"ts":"T","type":"turn"})

      expect(described_class.link("#{line}\n")).to eq("blake3:#{Lain::Ext.blake3_hex(line)}")
      expect(described_class.link(line)).to eq(described_class.link("#{line}\n"))
    end

    it "tells two lines apart by one byte" do
      expect(described_class.link(%({"n":1}))).not_to eq(described_class.link(%({"n":2})))
    end
  end

  describe ".splice!" do
    it "ends the same object with the link as its last key" do
      line = +%({"type":"turn"})

      expect(described_class.splice!(line, described_class::ORIGIN)).to equal(line)
      expect(line).to eq(%({"type":"turn","prev":"origin"}))
    end

    it "refuses a line that is not a JSON object" do
      expect { described_class.splice!(+"[1]", described_class::ORIGIN) }.to raise_error(ArgumentError, /\[1\]/)
    end
  end

  describe ".tip" do
    around { |example| Dir.mktmpdir { |dir| @path = File.join(dir, "s.ndjson") and example.run } }

    it "is the origin for an empty file" do
      File.write(@path, "")

      expect(described_class.tip(@path)).to eq(described_class::ORIGIN)
    end

    it "links the file's last line" do
      File.write(@path, %({"n":1}\n{"n":2}\n))

      expect(described_class.tip(@path)).to eq(described_class.link(%({"n":2})))
    end

    # A chained reopen seals a torn tail into a line of its own, so the tip vouches for its bytes.
    it "links a torn tail's bytes" do
      File.write(@path, %({"n":1}\n{"n":2}\n{"n":))

      expect(described_class.tip(@path)).to eq(described_class.link(%({"n":)))
    end
  end
end
