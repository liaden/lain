# frozen_string_literal: true

require "json"

RSpec.describe Lain::Improvement do
  def improvement(**overrides)
    described_class.new(
      note: "the timeout knob should default higher for slow bash tools",
      kind: "knob",
      project_hash: "abc123def456",
      session: "sess-1",
      **overrides
    )
  end

  describe "construction" do
    it "carries note, kind, evidence_digests, project_hash, session, and at" do
      record = improvement(evidence_digests: %w[deadbeef cafebabe])

      expect(record.note).to eq("the timeout knob should default higher for slow bash tools")
      expect(record.kind).to eq("knob")
      expect(record.evidence_digests).to eq(%w[deadbeef cafebabe])
      expect(record.project_hash).to eq("abc123def456")
      expect(record.session).to eq("sess-1")
      expect(record.at).to be_a(String)
    end

    it "defaults evidence_digests to empty" do
      expect(improvement.evidence_digests).to eq([])
    end

    it "is frozen" do
      expect(improvement).to be_frozen
    end

    it "is deeply immutable, hence Ractor-shareable without make_shareable" do
      expect(improvement(evidence_digests: %w[deadbeef cafebabe])).to be_ractor_shareable
    end

    it "rejects a kind outside the closed vocabulary" do
      expect { improvement(kind: "vibes") }.to raise_error(ArgumentError, /kind/)
    end

    described_class::KINDS.each do |kind|
      it "accepts #{kind.inspect} as a kind" do
        expect(improvement(kind:).kind).to eq(kind)
      end
    end

    it "rejects a blank note" do
      expect { improvement(note: "") }.to raise_error(ArgumentError, /note/)
    end

    it "rejects a nil project_hash" do
      expect { improvement(project_hash: nil) }.to raise_error(ArgumentError, /project_hash/)
    end

    it "rejects a nil session" do
      expect { improvement(session: nil) }.to raise_error(ArgumentError, /session/)
    end

    it "rejects a note over the byte size guard" do
      oversized = "a" * (described_class::NOTE_MAX_BYTES + 1)
      expect { improvement(note: oversized) }.to raise_error(ArgumentError, /note/)
    end

    it "accepts a note right at the byte size guard" do
      exact = "a" * described_class::NOTE_MAX_BYTES
      expect(improvement(note: exact).note.bytesize).to eq(described_class::NOTE_MAX_BYTES)
    end

    it "raises loudly, rather than writing a torn line, when evidence_digests alone would blow the line budget" do
      huge_digests = Array.new(200) { "a" * 64 }
      expect { improvement(evidence_digests: huge_digests) }.to raise_error(ArgumentError, /budget/)
    end
  end

  describe "#line" do
    it "is one JSON object per line, newline-terminated, tagged type: improvement" do
      record = improvement(evidence_digests: %w[deadbeef])
      line = record.line

      expect(line).to end_with("\n")
      expect(line.count("\n")).to eq(1)

      parsed = JSON.parse(line)
      expect(parsed).to include(
        "type" => "improvement",
        "note" => record.note,
        "kind" => "knob",
        "evidence_digests" => ["deadbeef"],
        "project_hash" => "abc123def456",
        "session" => "sess-1"
      )
      expect(parsed["at"]).to be_a(String)
    end
  end
end

RSpec.describe Lain::Improvement::Sink do
  subject(:sink) { described_class.new(paths:, session: "sess-1") }

  let(:tmp) { Dir.mktmpdir }
  let(:paths) { Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => tmp }) }

  after { FileUtils.remove_entry(tmp) }

  describe "an improvement lands durably under XDG state" do
    it "appends one NDJSON line under <XDG_STATE_HOME>/lain/improvements.ndjson carrying project_hash and session" do
      record = sink.append(note: "bash timeout is too aggressive for slow test suites", kind: "knob",
                           evidence_digests: %w[deadbeef])

      path = File.join(tmp, "lain", "improvements.ndjson")
      expect(File.exist?(path)).to be(true)

      lines = File.readlines(path, chomp: true)
      expect(lines.size).to eq(1)

      parsed = JSON.parse(lines.first)
      expect(parsed["project_hash"]).to eq(paths.project_hash)
      expect(parsed["session"]).to eq("sess-1")
      expect(parsed["note"]).to eq(record.note)
      expect(parsed["evidence_digests"]).to eq(%w[deadbeef])
    end

    it "appends a second call as a second line, never truncating the first" do
      sink.append(note: "first note", kind: "bug")
      sink.append(note: "second note", kind: "doc")

      path = File.join(tmp, "lain", "improvements.ndjson")
      lines = File.readlines(path, chomp: true)

      expect(lines.size).to eq(2)
      expect(JSON.parse(lines[0])["note"]).to eq("first note")
      expect(JSON.parse(lines[1])["note"]).to eq("second note")
    end
  end

  it "defaults project_hash to the injected Paths' own project_hash" do
    sink.append(note: "n", kind: "doc")
    path = File.join(tmp, "lain", "improvements.ndjson")

    expect(JSON.parse(File.readlines(path).first)["project_hash"]).to eq(paths.project_hash)
  end

  it "accepts an explicit project_hash override" do
    overridden = described_class.new(paths:, session: "sess-1", project_hash: "otherproj00")
    overridden.append(note: "n", kind: "doc")

    path = File.join(tmp, "lain", "improvements.ndjson")
    expect(JSON.parse(File.readlines(path).first)["project_hash"]).to eq("otherproj00")
  end

  describe "the line-atomicity budget boundary" do
    # Pads evidence_digests with one string to make a record's #line
    # serialize to an EXACT target byte size -- measured off a same-shaped
    # probe record rather than hand-counted, so this proof survives any
    # future change to JSON key order, spacing, or escaping. `project_hash`/
    # `session` match what `sink` itself attaches, so the measured probe and
    # the record actually appended are the same shape end to end.
    #
    # Replacing an empty array ("[]", 2 bytes) with a one-element array of L
    # plain (unescaped) ASCII characters ("[\"" + L chars + "\"]", L+4 bytes)
    # adds exactly L+2 bytes -- solving for L given a target line size.
    def digest_padded_to(target_bytes)
      probe = Lain::Improvement.new(note: "boundary probe", kind: "bug", project_hash: paths.project_hash,
                                    session: "sess-1", evidence_digests: [])
      padding = target_bytes - probe.line.bytesize - 2
      if padding.negative?
        raise "target #{target_bytes} too small for this record's fixed overhead (#{probe.line.bytesize})"
      end

      "a" * padding
    end

    it "accepts and appends a record that serializes to exactly LINE_MAX_BYTES" do
      record = sink.append(note: "boundary probe", kind: "bug",
                           evidence_digests: [digest_padded_to(Lain::Improvement::LINE_MAX_BYTES)])

      expect(record.line.bytesize).to eq(Lain::Improvement::LINE_MAX_BYTES)

      path = File.join(tmp, "lain", "improvements.ndjson")
      expect(File.readlines(path).size).to eq(1)
    end

    it "raises the line-budget error one byte over LINE_MAX_BYTES, before any write is attempted" do
      digest = digest_padded_to(Lain::Improvement::LINE_MAX_BYTES + 1)

      expect { sink.append(note: "boundary probe", kind: "bug", evidence_digests: [digest]) }
        .to raise_error(ArgumentError, /#{Lain::Improvement::LINE_MAX_BYTES}-byte line budget/)

      path = File.join(tmp, "lain", "improvements.ndjson")
      expect(File.exist?(path)).to be(false)
    end
  end
end

RSpec.describe Lain::Tools::ImprovementWrite do
  subject(:tool) { described_class.new(sink:) }

  let(:tmp) { Dir.mktmpdir }
  let(:paths) { Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => tmp }) }
  let(:sink) { Lain::Improvement::Sink.new(paths:, session: "sess-1") }

  after { FileUtils.remove_entry(tmp) }

  it "has a model-facing name and description" do
    expect(tool.name).to eq("improvement_write")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "declares note and kind as required, evidence_digests as optional" do
    schema = tool.input_schema
    expect(schema["properties"].keys).to eq(%w[note kind evidence_digests])
    expect(schema["required"]).to eq(%w[note kind])
  end

  it "advertises the closed kind vocabulary in its schema" do
    expect(tool.input_schema["properties"]["kind"]["enum"]).to match_array(Lain::Improvement::KINDS)
  end

  describe "an improvement lands durably under XDG state" do
    it "appends one NDJSON line under XDG_STATE_HOME/lain/improvements.ndjson carrying project_hash and session" do
      result = tool.call(note: "bash timeout is too aggressive for slow test suites", kind: "knob",
                         evidence_digests: "deadbeef, cafebabe")

      expect(result.is_error).to be(false)

      path = File.join(tmp, "lain", "improvements.ndjson")
      lines = File.readlines(path, chomp: true)
      expect(lines.size).to eq(1)

      parsed = JSON.parse(lines.first)
      expect(parsed["project_hash"]).to eq(paths.project_hash)
      expect(parsed["session"]).to eq("sess-1")
      expect(parsed["kind"]).to eq("knob")
      expect(parsed["evidence_digests"]).to eq(%w[deadbeef cafebabe])
    end

    it "tolerates a missing evidence_digests field, writing an empty list" do
      tool.call(note: "doc gap: no mention of the improvements sink", kind: "doc")

      path = File.join(tmp, "lain", "improvements.ndjson")
      expect(JSON.parse(File.readlines(path).first)["evidence_digests"]).to eq([])
    end
  end

  describe "input rejection" do
    it "raises Tool::InvalidInput on a blank note, before #perform ever runs" do
      expect { tool.call(note: "   ", kind: "knob") }.to raise_error(Lain::Tool::InvalidInput)
      expect(File.exist?(File.join(tmp, "lain", "improvements.ndjson"))).to be(false)
    end

    it "raises Tool::InvalidInput on a kind outside the closed vocabulary" do
      expect { tool.call(note: "n", kind: "vibes") }.to raise_error(Lain::Tool::InvalidInput)
    end
  end
end
