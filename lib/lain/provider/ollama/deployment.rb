# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # WHOSE ollama, and what stops being true when it is not ours.
      #
      # One arm of the "Provider / model" axis used to confound four variables
      # in a single value: local, free, small model, no caching. A cloud
      # deployment holds the encoder, the decoder and the wire format
      # byte-identical -- `ollama.com` serves the same native `/api/chat` --
      # and changes only hosted-ness and model class. That is the clean cut on
      # the provider axis, and it is the reason this namespace exists at all:
      # everything that differs between the two arms is gathered HERE, so the
      # provider can be read without a single `if local?`.
      #
      # {Local} and {Cloud} share NO superclass. They are told apart by what
      # they ANSWER -- {Sink::Null}'s idiom -- because a base class would
      # invite exactly one shared default, and every value in the set is one
      # the two arms disagree about. The message set is written down once, in
      # `spec/support/shared_examples/ollama_deployment.rb`:
      #
      #   api_base  headers  local?  capabilities  cache_profile
      #   request_timeout  max_retries  runner_status?  model_metadata?
      #   admission_width  apply(config)
      #
      # TWO PROBE PREDICATES, NOT ONE. `runner_status?` is `/api/ps` -- the
      # LOADED RUNNER listing, the only endpoint that states the window a model
      # is actually being served with. `model_metadata?` is `/api/show` -- the
      # GGUF's TRAINED maximum, a different and larger number, reached eagerly
      # at launch through `CLI::Backend#num_ctx`. Whether either answers on
      # `ollama.com` is one of the facts this chunk refuses to assume, and they
      # are two endpoints with two meanings: one predicate covering both is the
      # shape that comes back later as a bug.
      module Deployment
      end
    end
  end
end

# `local` FIRST: it is the arm every existing measurement is denominated in,
# and {Cloud}'s docstring cites it by name for the envelope it deliberately
# does not inherit. Neither leaf reads the other at class-body time, so this
# order is documentation rather than a binding.
require_relative "deployment/local"
require_relative "deployment/cloud"
