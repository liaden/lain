# frozen_string_literal: true

module Lain
  class Embedder
    # Batch embeddings over Ollama's native `/api/embed`. A free, local bench arm
    # -- the real-backend counterpart to {Static}. It REUSES {Provider::Ollama}'s
    # base-url/env posture: the same `ollama_api_base` Configuration option and
    # the same vendored Faraday stack, differing only in the path it posts to.
    #
    # THIS EMBEDDER sends no credential -- it exposes no key seam, so the
    # Configuration it builds carries no `ollama_api_key` and the inherited
    # `#headers` answers empty. A fact about this class, not the transport it
    # inherits: that can carry a Bearer since
    # {Provider::Ollama::Deployment}, and a caller who hands `config:` a
    # key-bearing Configuration will send it.
    #
    # The wire is `{ "model": ..., "embeddings": [[float, ...], ...], ... }` --
    # one vector per input text, in input order (verified against a local server;
    # nomic-embed-text returns dimension 768). A malformed `embeddings` raises
    # {APIError}, a non-2xx raises {APIStatusError} with the status lifted out,
    # and neither ever returns a silent empty vector -- that is the whole
    # contract this arm exists to keep honest.
    class Ollama < Embedder
      # Rooted at {Embedder::Error}, not {Lain::Error}, so `rescue
      # Embedder::Error` catches every failure of the round TRIP. That
      # difference in base is why the concern is parameterized.
      #
      # It does NOT catch every failure of `#embed`: a credential that cannot go
      # in a header is refused as a {Lain::Error} and propagates past it,
      # deliberately. This family means
      # the server said no, and a credential that cannot go in a header never
      # reached one -- so wrapping it here would report a round trip that did not
      # happen, and let a caller degrade past a misconfiguration it should hear.
      #
      # An {Embedder} reaching into `Provider::` is deliberate: what gets wrapped
      # is a {Provider::HTTP::Error} off the shared vendored transport, the same
      # reason {Transport} below subclasses {Provider::Ollama::Transport}.
      #
      # Deliberately absent: a `channel:` and a `spool:`, exactly as on
      # {Provider::Ollama} -- retries on this arm are not journaled and nothing
      # is salvageable after a crash.
      include Provider::ErrorWrapping.under(Embedder::Error)

      DEFAULT_MODEL = "nomic-embed-text"
      MALFORMED = "malformed /api/embed response"

      # {Provider::Ollama::Transport} with one more round trip on it -- stack,
      # base-url posture, `#local?` and `#headers` all INHERITED, not copied.
      #
      # `local?` is PER-INSTANCE, read off the base an instance will really
      # dial, so the CLASS method answers the vendored base's conservative
      # `false` even though every instance this embedder builds is loopback.
      # Ask an instance, never this class. Subclassing also makes the
      # `ollama_api_base` option registration explicit rather than a hidden
      # load-order coupling: this class cannot be DEFINED until the superclass's
      # file, which registers the option, has loaded.
      class Transport < Provider::Ollama::Transport
        EMBED_PATH = "api/embed"

        # `faraday.response :json` has already parsed the body, so `#body` is a
        # Hash. No headers parameter: unlike the chat path's sync_post, nothing
        # customizes embed headers.
        def embed_post(payload)
          connection.post(EMBED_PATH, payload)
        end
      end

      # @param model [String] the embed model; defaults to the pinned one
      # @param transport [#embed_post] injected in specs; a real {Transport} over
      #   the vendored connection otherwise
      # @param config [Configuration, nil] resolved options, `ollama_api_base`
      #   included; built from `api_base:` when omitted
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param api_base [String, nil] overrides `ollama_api_base` (default
      #   http://localhost:11434). There is deliberately no key parameter: the
      #   embed arm is the free local one, and nothing here builds a credential.
      def initialize(model: DEFAULT_MODEL, transport: nil, config: nil, sink: Sink::Null.new, api_base: nil)
        super()
        @model = model
        @config = config || build_config(api_base:)
        @transport = transport || Transport.new(@config, sink:)
      end

      # {#extract}'s own APIError for a torn body is raised INSIDE the wrapping
      # block and passes through it untouched.
      def embed(texts)
        wrapping_errors { extract(@transport.embed_post(payload_for(texts)).body || {}, texts.size) }
      end

      # @return [String] the pinned embed model, e.g. "nomic-embed-text".
      def model_id
        @model
      end

      private

      def payload_for(texts)
        { model: @model, input: texts }
      end

      # A torn response raises -- it is never handed back as data a caller might
      # treat as a real embedding.
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
    end
  end
end
