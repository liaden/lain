# frozen_string_literal: true

module Lain
  class Embedder
    # Batch embeddings over Ollama's native `/api/embed`. A free, local bench arm
    # -- the real-backend counterpart to {Static}. It REUSES {Provider::Ollama}'s
    # base-url/env posture: the same `ollama_api_base` Configuration option (no
    # api key -- Ollama is local) and the same vendored Faraday stack, differing
    # only in the path it posts to (`api/embed`, not `api/chat`).
    #
    # The wire is `{ "model": ..., "embeddings": [[float, ...], ...], ... }` --
    # one vector per input text, in input order (verified against a local server;
    # nomic-embed-text returns dimension 768). A missing/short/non-Float
    # `embeddings` is a malformed response and raises {APIError}; a non-2xx raises
    # {APIStatusError} with the status lifted out. Neither ever returns a silent
    # empty vector -- that is the whole contract this arm exists to keep honest.
    class Ollama < Embedder
      DEFAULT_MODEL = "nomic-embed-text"
      MALFORMED = "malformed /api/embed response"

      # Wraps a vendored transport error so nothing above the Embedder rescues a
      # Provider::HTTP class; the original is preserved as `#cause`.
      class APIError < Embedder::Error; end

      # A non-2xx response; `#status` is lifted out so callers branch on it
      # without unwrapping `#cause`.
      class APIStatusError < APIError
        attr_reader :status

        def initialize(message = nil, status: nil)
          super(message)
          @status = status
        end
      end

      # {Provider::Ollama::Transport} with one more round trip on it: same
      # vendored Faraday stack, same `ollama_api_base`/DEFAULT_API_BASE posture,
      # same local/keyless class predicates -- all INHERITED, not copied --
      # differing only in the path it posts to. Subclassing also makes the
      # `ollama_api_base` option registration explicit rather than a hidden
      # load-order coupling: the superclass's file registers it at its own load,
      # and this class cannot even be DEFINED until that file has loaded.
      class Transport < Provider::Ollama::Transport
        EMBED_PATH = "api/embed"

        # One non-streaming round trip. `faraday.response :json` has already
        # parsed the body, so `#body` is a Hash. No headers parameter: unlike
        # the chat path's sync_post, nothing ever customizes embed headers.
        def embed_post(payload)
          connection.post(EMBED_PATH, payload)
        end
      end

      # @param model [String] the embed model; defaults to the pinned one.
      # @param transport [#embed_post] injected in specs; a real {Transport} over
      #   the vendored connection otherwise.
      # @param api_base [String, nil] overrides `ollama_api_base` (default
      #   http://localhost:11434); no api key -- Ollama is local.
      def initialize(model: DEFAULT_MODEL, transport: nil, config: nil, sink: Sink::Null.new, api_base: nil)
        super()
        @model = model
        @config = config || build_config(api_base:)
        @transport = transport || Transport.new(@config, sink:)
      end

      def embed(texts)
        extract(@transport.embed_post(payload_for(texts)).body || {}, texts.size)
      rescue Provider::HTTP::Error => e
        raise wrap_error(e)
      end

      private

      def payload_for(texts)
        { model: @model, input: texts }
      end

      # Loud on any shape the wire should never send: the count must match the
      # request and each vector must be a non-empty list of Floats. Anything else
      # is a torn response, and a torn response raises -- it is never handed back
      # as data a caller might treat as a real embedding.
      def extract(body, expected)
        embeddings = body["embeddings"]
        problem = malformation(embeddings, expected)
        raise APIError, "#{MALFORMED}: #{problem}" if problem

        embeddings
      end

      def malformation(embeddings, expected)
        return "no embeddings array" unless embeddings.is_a?(Array)
        return "expected #{expected} vectors, got #{embeddings.size}" unless embeddings.size == expected
        return "a vector is not a list of numbers" unless embeddings.all? { |vector| vector?(vector) }
        return "vector dimensions differ across the batch" unless embeddings.map(&:size).uniq.size <= 1

        nil
      end

      # Numeric, not Float: JSON parses a decimal-less component (0, 1) as
      # Integer, and rejecting one would flag a legitimate wire value as torn.
      def vector?(vector)
        vector.is_a?(Array) && !vector.empty? && vector.all?(Numeric)
      end

      def build_config(api_base:)
        config = Provider::HTTP::Configuration.new
        config.ollama_api_base = api_base unless api_base.nil?
        config
      end

      def wrap_error(error)
        status = error.response.respond_to?(:status) ? error.response.status : nil
        status ? APIStatusError.new(error.message, status:) : APIError.new(error.message)
      end
    end
  end
end
