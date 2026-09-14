# frozen_string_literal: true

require "json"

# The local model emits its tool call as assistant TEXT on
# roughly half of first turns, and the turn then lands on the HEALTHY
# `end_turn` arm with nothing journaled at all. This record is the witness.
#
# It reports and never repairs -- the chunk's Open decision 3 refuses salvage,
# because a mis-parse would execute a call the model never properly expressed.
# So every field here is evidence a reader can check by hand against the turn,
# and none of it is a reconstructed call.
RSpec.describe Lain::Telemetry::MalformedResponse do
  subject(:event) do
    described_class.new(kind: :prose_tool_call, model: "qwen3-coder:30b", tool_name: "bash",
                        excerpt: "<function=bash>\n</function>")
  end

  it "is a frozen, Ractor-shareable value with structural equality" do
    twin = described_class.new(kind: :prose_tool_call, model: +"qwen3-coder:30b", tool_name: +"bash",
                               excerpt: +"<function=bash>\n</function>")
    expect(event).to eq(twin)
    expect(event.hash).to eq(twin.hash)
    expect(event).to be_deeply_frozen
  end

  describe "#to_journal" do
    it "tags itself malformed_response and names what was found" do
      expect(event.to_journal).to eq(
        "type" => "malformed_response", "kind" => :prose_tool_call, "model" => "qwen3-coder:30b",
        "tool_name" => "bash", "excerpt" => "<function=bash>\n</function>"
      )
    end

    it "round-trips through JSON to a parseable line" do
      expect(JSON.parse(JSON.generate(event.to_journal)))
        .to include("type" => "malformed_response", "kind" => "prose_tool_call", "tool_name" => "bash")
    end
  end

  # A malformed turn is the one turn whose text may be arbitrarily large --
  # the round-8 corpus carries a 2,787-character envelope holding a whole Rust
  # file. The record is a witness, not a copy: one NDJSON line stays scannable
  # and the Journal stays the thing a human greps.
  it "bounds the excerpt rather than copying the whole turn into one NDJSON line" do
    bounded = described_class.new(kind: :prose_tool_call, model: "m", tool_name: "bash",
                                  excerpt: "<function=bash>#{"x" * 5_000}</function>")

    expect(bounded.excerpt.length).to eq(Lain::Telemetry::MalformedResponse::EXCERPT_LIMIT)
    expect(bounded.excerpt).to start_with("<function=bash>")
  end

  # The bound is in CHARACTERS, so a multibyte envelope is cut at a codepoint
  # and never mid-character -- the Journal is NDJSON, and a record carrying
  # invalid UTF-8 is a line `JSON.parse` dies on rather than a finding.
  it "cuts a multibyte excerpt at a codepoint, never mid-character" do
    bounded = described_class.new(kind: :prose_tool_call, model: "m", tool_name: "bash",
                                  excerpt: "<function=bash>#{"\u{1f600}" * 500}</function>")

    expect(bounded.excerpt.length).to eq(Lain::Telemetry::MalformedResponse::EXCERPT_LIMIT)
    expect(bounded.excerpt).to be_valid_encoding
    expect(JSON.parse(JSON.generate(bounded.to_journal))["excerpt"]).to eq(bounded.excerpt)
  end

  # Loud failure, the same validate-then-freeze contract every sibling record
  # has. A record with no kind, no tool and no evidence would journal
  # `{"tool_name":""}` and read as a finding.
  it "refuses a record that names no reading, no tool, or no evidence" do
    expect(Lain::Telemetry::Carriers::MalformedResponse.new(kind: nil, tool_name: nil, excerpt: nil))
      .to be_invalid
    expect { described_class.new(kind: :something_else, model: "m", tool_name: "bash", excerpt: "x") }
      .to raise_error(ArgumentError, /kind must be one of prose_tool_call/)
    expect { described_class.new(kind: :prose_tool_call, model: "m", tool_name: nil, excerpt: "x") }
      .to raise_error(ArgumentError, /tool_name must name the tool the envelope named/)
    expect { described_class.new(kind: :prose_tool_call, model: "m", tool_name: "bash", excerpt: "") }
      .to raise_error(ArgumentError, /excerpt must carry the text the reading was made from/)
  end

  # `model` is the one field the wire may genuinely omit: `/api/chat`'s body
  # carries it on every real response, but a hand-assembled or replayed body
  # need not, and a nil there is an absence rather than a defect.
  it "tolerates an absent model, the one field the wire may omit" do
    expect(described_class.new(kind: :prose_tool_call, tool_name: "bash", excerpt: "<function=bash></function>"))
      .to have_attributes(model: nil)
  end

  # `kind` is coerced BEFORE the guard sees it, the sibling {ProviderWait}'s
  # own spelling. Without the coercion a String `kind` refused with
  # `got prose_tool_call` -- naming the REJECTED value as the WANTED one,
  # since `%<value>s` renders a Symbol and a String identically, so the one
  # message a caller most needs to read was the one that could not be read.
  # A journal reader replaying a recorded line has only the String, JSON
  # having no Symbol, so it is also the spelling that arrives in practice.
  it "takes the String spelling a replayed record carries, and still names a nil kind" do
    expect(described_class.new(kind: "prose_tool_call", tool_name: "bash", excerpt: "<function=bash></function>"))
      .to have_attributes(kind: :prose_tool_call)
    expect { described_class.new(kind: nil, tool_name: "bash", excerpt: "x") }
      .to raise_error(ArgumentError, /kind must be one of prose_tool_call/)
  end
end
