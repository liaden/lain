# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::ImprovementWrite do
  subject(:tool) { described_class.new(sink:) }

  let(:tmp) { Dir.mktmpdir }
  let(:paths) { Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => tmp }) }
  let(:sink) { Lain::Improvement::Sink.new(paths:, session: "sess-1") }
  let(:path) { File.join(tmp, "lain", "improvements.ndjson") }
  let(:note) { { note: "bash timeout is too aggressive", kind: "knob", evidence_digests: "deadbeef, cafebabe" } }

  after { FileUtils.remove_entry(tmp) }

  it "answers already recorded and adds no line when the same note is sent again" do
    tool.call(**note)
    result = tool.call(**note)

    expect(result.is_error).to be(false)
    expect(result.content).to include("already recorded")
    expect(File.readlines(path).size).to eq(1)
    expect(sink.appended).to eq(1)
  end

  it "stores a second line when the kind or the note changes" do
    tool.call(**note)
    tool.call(**note, kind: "bug")
    tool.call(**note, note: "a different note")

    expect(File.readlines(path).size).to eq(3)
  end

  it "stores a note that differs in evidence digests" do
    tool.call(**note)
    tool.call(**note, evidence_digests: "deadbeef")

    expect(File.readlines(path).size).to eq(2)
  end
end
