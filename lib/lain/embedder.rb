# frozen_string_literal: true

module Lain
  # The seam between Lain and an embedding model: many texts in, many vectors
  # out, in one batched round trip. It mirrors {Provider}'s posture -- a base
  # that declares the duck, one concrete subclass per backend -- because memory
  # retrieval (M6) must be able to A/B a real embedding backend against a
  # deterministic, PHI-free one on the same seam, and swap either without a
  # caller noticing.
  #
  # The batch shape is the point: crossing a network (or an FFI, later) once per
  # {#embed} rather than once per text is what keeps the boundary cheap. A
  # concrete embedder returns one equal-dimension `Array<Float>` per input text,
  # in input order, and NEVER a silent empty vector for a broken response -- a
  # malformed or non-2xx reply is a named {Error}, so a caller can never mistake
  # a failure for a legitimately empty embedding.
  class Embedder
    # The root of the embedder error family, so a caller rescues one type across
    # every backend rather than each backend's own classes.
    class Error < Lain::Error; end

    # @param texts [Array<String>]
    # @return [Array<Array<Float>>] one vector per input text, all equal length
    def embed(_texts)
      raise NotImplementedError, "#{self.class} must implement #embed"
    end
  end
end

require_relative "embedder/static"
require_relative "embedder/ollama"
