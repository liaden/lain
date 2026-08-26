# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # WHOSE ollama, and what stops being true when it is not ours.
      #
      # One arm of the "Provider / model" axis used to confound four variables
      # in a single value: local, free, small model, no caching. A cloud
      # deployment holds the encoder, decoder and wire format byte-identical --
      # `ollama.com` serves the same native `/api/chat` -- and changes only
      # hosted-ness and model class. Everything that differs is gathered HERE,
      # so the provider reads without a single `if local?`.
      #
      # {Local} and {Cloud} share NO superclass. They are told apart by what
      # they ANSWER, because a base class would invite exactly one shared
      # default and every value in the set is one the two arms disagree about.
      # The message set is written down once, in a shared example:
      #
      #   api_base  headers  local?  capabilities  cache_profile
      #   request_timeout  max_retries  runner_status?  model_metadata?
      #   admission_width  apply(config)
      #
      # TWO PROBE PREDICATES, NOT ONE. `runner_status?` is `/api/ps`, the
      # LOADED RUNNER listing and the only endpoint stating the window a model
      # is actually being served with; `model_metadata?` is `/api/show`, the
      # GGUF's TRAINED maximum, a different and larger number reached eagerly at
      # launch. Two endpoints with two meanings, and whether either answers on
      # `ollama.com` is unverified -- one predicate covering both is the shape
      # that comes back later as a bug.
      module Deployment
      end
    end
  end
end

# `local` FIRST: it is the arm every existing measurement is denominated in.
# Neither leaf reads the other at class-body time, so the order is
# documentation rather than a binding.
require_relative "deployment/local"
require_relative "deployment/cloud"
