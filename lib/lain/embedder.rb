# frozen_string_literal: true

module Lain
  # The seam between Lain and an embedding model: many texts in, many vectors
  # out, in one batched round trip. It mirrors {Provider}'s posture so memory
  # retrieval can A/B a real embedding backend against a deterministic, PHI-free
  # one on the same seam.
  #
  # The batch shape is the point: crossing a network once per {#embed} rather
  # than once per text is what keeps the boundary cheap. A broken response is
  # NEVER a silent empty vector -- a malformed or non-2xx reply is a named
  # {Error}, so a failure cannot be mistaken for a legitimately empty embedding.
  class Embedder
    # One type to rescue across every backend, rather than each backend's own.
    class Error < Lain::Error; end

    # @param texts [Array<String>]
    # @return [Array<Array<Float>>] one vector per input text, all equal length
    def embed(texts)
      raise NotImplementedError, "#{self.class} must implement #embed"
    end

    # Abstract like {#embed}, so every backend states its own identity rather
    # than inheriting a guess.
    #
    # @return [String] the model identity a consumer's #why should name --
    #   Ollama's pinned model id, Static's honest "not a real model" label --
    #   never this Ruby class's name, which names the backend but not what it
    #   ran.
    def model_id
      raise NotImplementedError, "#{self.class} must implement #model_id"
    end
  end
end

require_relative "embedder/static"
require_relative "embedder/ollama"
