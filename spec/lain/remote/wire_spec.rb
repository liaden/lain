# frozen_string_literal: true

# The bytes are the ones crates/lain-wire commits and its own tests pin, read
# from there rather than copied, so a Rust-side change to the wire fails here.
RSpec.describe Lain::Remote::Wire do
  let(:fixtures) { File.join(Lain::Paths::Shipped::GEM_ROOT, "crates", "lain-wire", "tests", "fixtures") }
  let(:epoch) { 0x9e37_79b9_7f4a_7c15 }
  let(:verdict) { Lain::Approval::Verdict }

  let(:source) { { session: "2026-11-17T10-00-00-abc", project: "/work" } }

  def committed(name) = File.binread(File.join(fixtures, "#{name}.msgpack"))

  def call_item
    described_class::Item::ParkedCall.new(id: "c1", requester: "main", tool: "bash", input: "ls -la", cwd: "/work",
                                          why: "outside bounds", postponed: true, asked_at: 1_700_000_000, **source)
  end

  def gate_item
    described_class::Item::GateQuestion.new(id: "g1", requester: "coordinator", epic: "nyotes", stage: "wave",
                                            issues: %w[a b c], question: "merge the wave?", asked_at: 1_700_000_001,
                                            **source)
  end

  def question_item
    described_class::Item::Question.new(id: "q1", requester: "main", question: "which branch?", options: %w[main dev],
                                        asked_at: 1_700_000_002, **source)
  end

  def delta = described_class::Delta.new(cursor: 9, added: [call_item, gate_item, question_item], settled: ["old"])

  # Every message the Rust tests encode, by fixture name, with the type it decodes as.
  def messages = agenda_messages.merge(answer_messages)

  def agenda_messages
    wire = described_class
    {
      "hello" => [wire::Hello, wire::Hello.new(wire_version: 1, token: "tok", cursor: 7)],
      "agenda_parked_call" => [wire::Item, call_item],
      "agenda_gate_question" => [wire::Item, gate_item],
      "agenda_question" => [wire::Item, question_item],
      "delta" => [wire::Delta, delta],
      "welcome" => [wire::Welcome, wire::Welcome.new(wire_version: 1, head: 9, epoch:)],
      "cursor" => [wire::Cursor, wire::Cursor.new(cursor: 7, epoch:)],
      "cursor_fresh" => [wire::Cursor, wire::Cursor.new(cursor: 0, epoch: nil)],
      "agenda_page" => [wire::AgendaPage, wire::AgendaPage.new(epoch:, cursor: 9, reset: false, deltas: [delta])]
    }
  end

  def answer_messages
    wire = described_class
    {
      "answer_call" => [wire::Answer, wire::Answer::Call.new(id: "c1", verdict: verdict::Deny.new(note: "no"),
                                                             device: nil)],
      "answer_gate" => [wire::Answer, wire::Answer::Gate.new(
        id: "g1", device: nil,
        verdicts: [["a", verdict::Approve.new], ["b", verdict::Hold.new(note: "later")], ["c", verdict::Deny.new]]
      )],
      "answer_question" => [wire::Answer, wire::Answer::Question.new(id: "q1", option: "dev", text: nil, device: nil)],
      "answer_call_device" => [wire::Answer, wire::Answer::Call.new(id: "c1", verdict: verdict::Approve.new,
                                                                    device: "pixel")],
      "answers_page" => [wire::AnswersPage, answers_page]
    }
  end

  def answers_page
    described_class::AnswersPage.new(
      epoch:, cursor: 2, reset: true,
      answers: [described_class::Answer::Call.new(id: "c1", verdict: verdict::Approve.new, device: nil),
                described_class::Answer::Question.new(id: "q1", option: "dev", text: nil, device: nil)]
    )
  end

  it "speaks the version the relay serves" do
    expect(described_class::VERSION).to eq(2)
  end

  describe "Ruby and Rust encode alike" do
    it "encodes each message to the bytes crates/lain-wire commits" do
      mismatched = messages.reject { |name, (_type, value)| described_class.pack(value) == committed(name) }

      expect(mismatched.keys).to be_empty
    end

    it "decodes each committed fixture to the same message" do
      decoded = messages.to_h { |name, (type, _value)| [name, described_class.unpack(committed(name), as: type)] }

      expect(decoded).to eq(messages.transform_values(&:last))
    end
  end

  # Ruby packs a binary String as msgpack bin, which serde will not read as a String.
  it "packs a binary-encoded String as text, the same bytes as its UTF-8 twin" do
    binary = described_class::Hello.new(wire_version: 1, token: "tok".b, cursor: 7)

    expect(described_class.pack(binary)).to eq(committed("hello"))
  end

  describe "what a peer may send that Ruby must read the way Rust does" do
    it "reads an absent optional key as nil" do
      expect([described_class.unpack(committed("verdict_note_absent"), as: described_class::Verdict),
              described_class.unpack(committed("answer_question_absent"), as: described_class::Answer),
              described_class.unpack(committed("cursor_epoch_absent"), as: described_class::Cursor)])
        .to eq([verdict::Approve.new,
                described_class::Answer::Question.new(id: "q1", option: nil, text: nil, device: nil),
                described_class::Cursor.new(cursor: 0, epoch: nil)])
    end

    it "ignores an unknown extra field" do
      expect(described_class.unpack(committed("hello_extra_field"), as: described_class::Hello))
        .to eq(described_class::Hello.new(wire_version: 1, token: "tok", cursor: 7))
    end

    it "reads a map16 message and a newer version's hello" do
      expect([described_class.unpack(committed("hello_map16"), as: described_class::Hello).wire_version,
              described_class.unpack(committed("hello_v3"), as: described_class::Hello).wire_version]).to eq([1, 3])
    end

    %w[session project].each do |field|
      it "refuses an item without the #{field} it came from, naming the field" do
        lacking = MessagePack.unpack(described_class.pack(call_item))
        lacking["ParkedCall"].delete(field)

        expect { described_class.unpack(MessagePack.pack(lacking), as: described_class::Item) }
          .to raise_error(described_class::Malformed, /#{field}/)
      end
    end

    it "refuses a positional array, as the Rust decoder does" do
      expect { described_class.unpack(committed("hello_positional"), as: described_class::Hello) }
        .to raise_error(described_class::Malformed, /map/)
    end

    it "refuses a variant it does not know, naming it" do
      expect { described_class.unpack(committed("agenda_unknown_variant"), as: described_class::Item) }
        .to raise_error(described_class::Malformed, /variant/)
    end

    it "refuses a field of the wrong type, naming the field" do
      bytes = MessagePack.pack("wire_version" => "1", "token" => "tok", "cursor" => 7)

      expect { described_class.unpack(bytes, as: described_class::Hello) }
        .to raise_error(described_class::Malformed, /wire_version/)
    end

    it "refuses a missing required field, naming it" do
      expect { described_class.unpack(MessagePack.pack("token" => "tok", "cursor" => 7), as: described_class::Hello) }
        .to raise_error(described_class::Malformed, /wire_version/)
    end
  end
end
