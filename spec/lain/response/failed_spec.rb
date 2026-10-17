# frozen_string_literal: true

RSpec.describe Lain::Response::Failed do
  let(:prose_call) do
    Lain::Response.new(content: [{ "type" => "text", "text" => "<tool_call>\n<function=bash>" }],
                       stop_reason: :malformed)
  end

  describe ".refusing" do
    it "hands back a response that is an answer" do
      answer = Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn)

      expect(described_class.refusing(answer)).to be(answer)
    end

    it "raises on a failed stop, carrying the Failure and saying its message" do
      expect { described_class.refusing(prose_call) }.to raise_error(described_class) { |error|
        expect(error.failure).to eq(prose_call.failure)
        expect(error.message).to eq(Lain::Response::Failure::PROSE_CALL)
      }
    end

    it "raises with a backtrace, so the failure can be traced to its caller" do
      expect { described_class.refusing(prose_call) }.to raise_error(described_class) { |error|
        expect(error.backtrace).not_to be_nil
      }
    end

    it "is a Lain::Error, so a caller rescuing the harness's own errors catches it" do
      expect { described_class.refusing(prose_call) }.to raise_error(Lain::Error)
    end
  end

  it "carries a Failure that is deeply frozen" do
    expect(described_class.new(prose_call.failure).failure).to be_deeply_frozen
  end
end
