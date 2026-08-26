# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      module Deployment
        Local = Data.define

        # The loopback arm, as an object rather than as five assumptions
        # spread through {Ollama}.
        #
        # Every value here is the one the ollama arm has answered since it was
        # written, and that is the whole point: `Local` is a pure RESTATEMENT.
        # A bench axis is only readable if the arm it is measured against did
        # not move underneath it, so this class introducing a new number would
        # invalidate every ollama measurement already recorded rather than add
        # one.
        #
        # It carries no state at all -- there is exactly one loopback server to
        # talk about -- so it is a memberless `Data`: still a value, still
        # `Ractor.shareable?`, and `Local.new == Local.new`. The split into a
        # bare `Data.define` and this reopen is the constant-scoping trap
        # `Request::SYSTEM_PREFIX` documents; the docstring sits on the reopen
        # because `Local` is not a unique name in `lib/` (`Exec::Local`), and
        # `.rubocop.yml`'s `AllowedConstants` list would blind the cop
        # repo-wide if it carried a name that recurs.
        class Local
          # A loopback server asks for no credential, and the empty Hash is a
          # CONSTANT rather than a `{}.freeze` per call so `#headers` hands
          # back the same object every time -- the deep-freeze invariant the
          # sibling {Cloud} has to work for.
          NO_AUTHORIZATION = {}.freeze

          # Today's list, restated. It is pinned against
          # {Provider::Ollama::CAPABILITIES} by a spec rather than read from it:
          # if the two ever disagree, this class has stopped being a
          # restatement, and that is a fact worth failing on rather than
          # absorbing silently.
          CAPABILITIES = %i[streaming thinking structured_output].freeze

          # The vendored envelope, unchanged. 300s is not generosity: this is
          # the one arm whose honest shape is a model thinking for six minutes,
          # and the whole ollama suite is measured against it.
          REQUEST_TIMEOUT = 300
          MAX_RETRIES = 3

          def api_base = Transport::DEFAULT_API_BASE

          def headers = NO_AUTHORIZATION

          def local? = true

          def capabilities = CAPABILITIES

          def cache_profile = CacheProfile::NO_CACHING

          def request_timeout = REQUEST_TIMEOUT

          def max_retries = MAX_RETRIES

          # `/api/ps` lists the runners this server has resident, which is the
          # only place the window a model is ACTUALLY being served with is
          # stated.
          def runner_status? = true

          # `/api/show` reads the GGUF's own KV table -- the trained maximum,
          # never a served window.
          def model_metadata? = true

          # nil, NOT 1. `Provider::Admission.build` already answers
          # `DEFAULT_WIDTH = 1` for a local endpoint, and a DECLARED width
          # takes precedence over that locality rule -- so saying "1" here
          # would shadow the rule with a number that merely happens to agree
          # with it today. "Nobody said" is the true answer, and it is the one
          # the three-way precedence needs to hear.
          def admission_width = nil

          # A COMPLETE POSITION, written unconditionally. `apply` states what
          # the configuration IS, never a difference from what it found, so a
          # configuration always describes exactly one deployment no matter
          # what ran before it.
          #
          # THE KEY IS CLEARED, and that is the field this method exists for.
          # Not writing one is not enough: a configuration that {Cloud} touched
          # carries an `ollama_api_key`, and leaving it beside a loopback base
          # sends an ollama.com Bearer to `http://localhost:11434` in plaintext,
          # to whatever is listening on that port. Today's arm cannot leak a key
          # because it has no key concept at all; `Local` has to PRESERVE that
          # property rather than depend on nobody having set one.
          #
          # `--api-base` is deliberately NOT honoured here. An earlier design
          # wrote the base only when unset so the flag would survive, and that
          # is precisely what let one arm's base sit beside another's
          # credential -- this object cannot tell an operator's flag from the
          # previous deployment's write, and only the provider can, because
          # only it knows whether `api_base:` was passed. So the hand-off is
          # explicit: the caller applies the deployment first and re-applies
          # an explicit `api_base:` afterwards, which is the order
          # `Provider::Ollama#build_config` is specified to use.
          #
          # @param config [Provider::HTTP::Configuration]
          # @return [Provider::HTTP::Configuration] the same object, so a
          #   caller can keep composing
          def apply(config)
            config.ollama_api_base = api_base
            config.ollama_api_key = nil
            config.request_timeout = request_timeout
            config.max_retries = max_retries
            config
          end
        end
      end
    end
  end
end
