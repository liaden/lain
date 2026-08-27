# frozen_string_literal: true

# The record a streamed turn that never said it was finished leaves in the
# Journal. The EMITTER is spec'd at the provider seam
# (`spec/lain/provider/ollama/stream_assembler_spec.rb`); what is asserted here
# is the VALUE -- its closed `kind` enum, the join key that ties it to a round
# trip, the counts that make a truncation checkable by hand, and the refusals
# that keep a record from claiming a measurement it does not have.
#
# Ollama's NDJSON stream carries its `done` line last and nothing before it says
# how many lines to expect, so a connection that dies mid-answer is
# indistinguishable from one that finished -- the reassembled body reads
# `done: true` either way. This record is the difference.
RSpec.describe Lain::Telemetry::TruncatedStream do
  subject(:event) do
    described_class.new(kind: :unterminated, model: "qwen3:4b", request_digest: "sha256:abc",
                        frames: 57, accumulated_bytes: 2_841, tool_calls: 0)
  end

  it "carries what was missing, the round trip it belongs to, the model, and how far the stream got" do
    expect(event).to have_attributes(kind: :unterminated, model: "qwen3:4b", request_digest: "sha256:abc",
                                     frames: 57, accumulated_bytes: 2_841, tool_calls: 0)
  end

  it "is a frozen, Ractor-shareable value with structural equality" do
    twin = described_class.new(kind: :unterminated, model: +"qwen3:4b", request_digest: +"sha256:abc",
                               frames: 57, accumulated_bytes: 2_841, tool_calls: 0)

    expect(event).to eq(twin)
    expect(event.hash).to eq(twin.hash)
    expect(event).to be_deeply_frozen
  end

  describe "#to_journal" do
    it "tags itself truncated_stream and names the join key with every count" do
      expect(event.to_journal).to eq(
        "type" => "truncated_stream", "kind" => :unterminated, "model" => "qwen3:4b",
        "request_digest" => "sha256:abc", "frames" => 57, "accumulated_bytes" => 2_841, "tool_calls" => 0
      )
    end

    it "round-trips through JSON to a parseable line" do
      expect(JSON.parse(JSON.generate(event.to_journal)))
        .to include("type" => "truncated_stream", "kind" => "unterminated", "frames" => 57)
    end
  end

  # The one field that makes an occurrence actionable at 3am. A session runs
  # dozens of turns against one model over ONE reused Provider -- more than one
  # round trip can be in flight through the same tap -- so `model` plus NDJSON
  # adjacency cannot say WHICH stream died. This is the same join key
  # {Lain::Telemetry::Salvaged} carries onto the RequestSent.
  it "refuses a record that cannot name the round trip it describes" do
    expect do
      described_class.new(kind: :unterminated, request_digest: nil, frames: 1,
                          accumulated_bytes: 1, tool_calls: 0)
    end
      .to raise_error(ArgumentError, /request_digest must name the round trip/)
  end

  # The second reading the record has to express: the stream DID terminate, so
  # the body is trustworthy prose, but the terminal line carried no token counts
  # -- which decodes to all-zero usage and makes the turn look free.
  describe "a terminal frame that carried no token counts" do
    subject(:absent) do
      described_class.new(kind: :counts_absent, model: "qwen3:4b", request_digest: "sha256:abc",
                          frames: 4, accumulated_bytes: 11, tool_calls: 0)
    end

    it "names the absent counts as its own kind rather than as an unterminated stream" do
      expect(absent.kind).to eq(:counts_absent)
      expect(absent.to_journal).to include("type" => "truncated_stream", "kind" => :counts_absent)
    end
  end

  # The most dangerous truncation shape, and the one a byte count alone erases:
  # tool-call frames carry no message text, so a stream severed with three calls
  # in flight would otherwise journal `accumulated_bytes: 0` and read exactly
  # like three empty keepalives.
  it "counts tool-call frames separately, so a severed call is not read as an empty stream" do
    severed = described_class.new(kind: :unterminated, request_digest: "sha256:abc", frames: 3,
                                  accumulated_bytes: 0, tool_calls: 3)

    expect(severed.to_journal).to include("accumulated_bytes" => 0, "tool_calls" => 3)
  end

  # A stream severed before its first line delivered anything is the shape most
  # worth recording, so zero is a legitimate figure on every count -- and
  # `presence:` would have refused it.
  it "records a stream that delivered nothing at all" do
    expect(described_class.new(kind: :unterminated, request_digest: "sha256:abc", frames: 0,
                               accumulated_bytes: 0, tool_calls: 0))
      .to have_attributes(frames: 0, accumulated_bytes: 0, tool_calls: 0, model: nil)
  end

  # Loud failure, the same validate-then-freeze contract every sibling record
  # has. A record with no kind and no counts would journal `{}` and read as a
  # finding nobody can check.
  it "refuses a record that names no reading or no counts" do
    expect(Lain::Telemetry::Carriers::TruncatedStream.new(kind: nil, request_digest: nil, frames: nil,
                                                          accumulated_bytes: nil, tool_calls: nil))
      .to be_invalid
    expect do
      described_class.new(kind: :sort_of_done, request_digest: "d", frames: 1, accumulated_bytes: 1,
                          tool_calls: 0)
    end
      .to raise_error(ArgumentError, /kind must be one of unterminated, counts_absent/)
    expect do
      described_class.new(kind: :unterminated, request_digest: "d", frames: nil, accumulated_bytes: 1,
                          tool_calls: 0)
    end
      .to raise_error(ArgumentError, /frames must be the number of NDJSON frames/)
    expect do
      described_class.new(kind: :unterminated, request_digest: "d", frames: 1, accumulated_bytes: -1,
                          tool_calls: 0)
    end
      .to raise_error(ArgumentError, /accumulated_bytes must be the message bytes/)
    expect do
      described_class.new(kind: :unterminated, request_digest: "d", frames: 1, accumulated_bytes: 1,
                          tool_calls: nil)
    end
      .to raise_error(ArgumentError, /tool_calls must be the number of tool calls/)
  end

  # A String `kind` renders identically to a Symbol under `%<value>s`, so an
  # uncoerced one used to be refused with a message naming the rejected value as
  # the wanted one -- {Telemetry::MalformedResponse}'s spelling, for its reason.
  it "accepts the kind as a String and journals it as the Symbol" do
    expect(described_class.new(kind: "counts_absent", request_digest: "d", frames: 1, accumulated_bytes: 1,
                               tool_calls: 0).kind)
      .to eq(:counts_absent)
  end
end
