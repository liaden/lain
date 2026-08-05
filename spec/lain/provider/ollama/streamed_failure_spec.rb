# frozen_string_literal: true

require "json"

# T38. The unit half of "a failed stream must say what ollama said". The
# provider-level examples in ollama_streaming_spec.rb drive real Faraday over
# WebMock, which delivers a stubbed body as ONE chunk -- so the two shapes that
# actually broke in production are only reachable here: an error object split
# across TCP reads, and the same handler being replayed by faraday-retry.
RSpec.describe Lain::Provider::Ollama::StreamedFailure do
  # ErrorMiddleware asks the provider to turn a body into a message; every
  # vendored provider answers with ErrorBody, so the double does too.
  let(:provider) do
    Class.new do
      def parse_error(response) = Lain::Provider::HTTP::Provider::ErrorBody.parse(response)
    end.new
  end

  def failure = described_class.new(provider)

  def response(body:, status:)
    Struct.new(:body, :status).new(body, status)
  end

  # What the outer ErrorMiddleware raises once streaming has consumed the body:
  # the real status, an empty body, and a message it could only invent.
  def consumed_error(status: 404, body: "", message: "An unknown error occurred")
    Lain::Provider::HTTP::Error.new(response(body:, status:), message)
  end

  def error_body(message) = JSON.generate("error" => message)

  describe "#reraise" do
    it "raises what ollama said instead of the middleware's fallback literal" do
      subject = failure
      subject.feed(error_body("model 'no-such-model-xyz' not found"))

      expect { subject.reraise(consumed_error) }
        .to raise_error(Lain::Provider::HTTP::Error, "model 'no-such-model-xyz' not found")
    end

    # The status is the response's own. Carrying the message by relabeling a
    # 404 as a retryable 500 -- what parse_streaming_error's guess does -- is
    # RES1, and the point of raising from the transport rather than from the
    # on_data callback is that the real status is right there.
    it "keeps the response's real status, and the class the middleware maps it to" do
      subject = failure
      subject.feed(error_body("model is required"))

      expect { subject.reraise(consumed_error(status: 400)) }
        .to raise_error(Lain::Provider::HTTP::BadRequestError, "model is required")
    end

    # The class is re-chosen from the recovered message, not inherited from the
    # error raised without one -- the 400/429 context-length sniff reads the
    # message, so a body-less 400 can only ever be a plain BadRequestError.
    it "re-runs the middleware's own mapping over the recovered message" do
      subject = failure
      subject.feed(error_body("input length exceeds context length"))

      expect { subject.reraise(consumed_error(status: 400)) }
        .to raise_error(Lain::Provider::HTTP::ContextLengthExceededError)
    end

    it "reassembles an error object split across chunks" do
      subject = failure
      ['{"error":"model ', "'no-such", "-model-xyz' not fo", 'und"}'].each { |chunk| subject.feed(chunk) }

      expect { subject.reraise(consumed_error) }
        .to raise_error(Lain::Provider::HTTP::Error, "model 'no-such-model-xyz' not found")
    end

    # faraday-retry replays the attempt through the SAME on_data handler. An
    # accumulator that only appends holds {...}{...} from attempt two on, which
    # parses as neither -- the message was being destroyed on exactly the
    # statuses that get retried.
    it "reports the LAST attempt's body, not a concatenation of every attempt" do
      subject = failure
      3.times { subject.feed(error_body("model runner has unexpectedly stopped")) }

      expect { subject.reraise(consumed_error(status: 500)) }
        .to raise_error(Lain::Provider::HTTP::ServerError, "model runner has unexpectedly stopped")
    end

    it "reports the newest body when a replayed attempt answers differently" do
      subject = failure
      subject.feed(error_body("model runner has unexpectedly stopped"))
      subject.feed(error_body("model 'gone-away' not found"))

      expect { subject.reraise(consumed_error) }
        .to raise_error(Lain::Provider::HTTP::Error, "model 'gone-away' not found")
    end

    it "re-raises the original error when the stream carried no body at all" do
      original = consumed_error
      expect { failure.reraise(original) }.to raise_error(original)
    end

    # Faraday calls on_data once with an empty string when a response has no
    # body (Env#stream_response), so this is a shape that really arrives.
    it "re-raises the original error when the only chunk was empty" do
      subject = failure
      subject.feed("")
      original = consumed_error

      expect { subject.reraise(original) }.to raise_error(original)
    end

    # A body that never completed is not a sentence; the middleware's literal
    # is wrong but at least it is not half a JSON object.
    it "re-raises the original error when the body never finished arriving" do
      subject = failure
      subject.feed('{"error": "model ')
      original = consumed_error

      expect { subject.reraise(original) }.to raise_error(original)
    end

    # The outer response wins when it kept its body -- there is nothing to add,
    # and preferring the buffer would let a stale attempt overwrite a message
    # the middleware read from the response in front of it.
    it "leaves an error that already speaks from its own body alone" do
      subject = failure
      subject.feed(error_body("model 'gone-away' not found"))
      original = consumed_error(body: error_body("model is required"), message: "model is required")

      expect { subject.reraise(original) }.to raise_error(original)
    end

    # An Error built from a bare String has no response at all (its initializer
    # shifts the String into the message), which is the same absence.
    it "re-raises an error carrying no response" do
      subject = failure
      subject.feed(error_body("model is required"))
      original = Lain::Provider::HTTP::Error.new("boom")

      expect { subject.reraise(original) }.to raise_error(original)
    end

    # The guarantee #reraise's doc rests on: it never returns. A 2xx would make
    # ErrorMiddleware.parse_error return a message instead of raising, so a
    # success status is refused before it can get there.
    it "re-raises rather than returning when the status is a success" do
      subject = failure
      subject.feed(error_body("model is required"))
      original = Lain::Provider::HTTP::Error.new(response(body: "", status: 200), "not an error")

      expect { subject.reraise(original) }.to raise_error(original)
    end
  end
end
