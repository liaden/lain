# frozen_string_literal: true

module Lain
  class Provider
    ModelIdentity = Data.define(:digest, :quant)

    # The weights a run used, as a server states them: the manifest digest of the
    # pulled model and the quantization its file declares. A tag such as
    # `qwen3:4b` can be re-pulled to different weights, so the name alone does
    # not say what ran.
    #
    # A part nobody could read is a word, never nil, so two runs compare
    # without a nil case.
    class ModelIdentity
      # The server did not answer, or answered without the field.
      UNRECORDED = "unrecorded"

      def initialize(digest:, quant:)
        super(digest: -digest.to_s, quant: -quant.to_s)
      end
    end
  end
end
