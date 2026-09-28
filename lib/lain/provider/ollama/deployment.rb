# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      Deployment = Data.define(:api_key, :admission_width)

      # WHOSE ollama, and what stops being true when it is not ours.
      #
      # One arm of the "Provider / model" axis used to confound four variables
      # in a single value: local, free, small model, no caching. The hosted
      # deployment holds the encoder, decoder and wire format byte-identical --
      # `ollama.com` serves the same native `/api/chat` -- and changes only
      # hosted-ness and model class. Everything that differs is gathered HERE,
      # so the provider reads without a single `if local?`.
      #
      # ONE VALUE, TWO ARMS, and the credential is what tells them apart:
      # {.local} holds no key and {.cloud} cannot exist without one. The eleven
      # messages both answer are written down once, in
      # `spec/support/shared_examples/ollama_deployment.rb`, so a third
      # deployment that forgets one fails there rather than at the first turn
      # against a real endpoint.
      #
      # TWO PROBE PREDICATES, NOT ONE. `runner_status?` is `/api/ps`, the
      # LOADED RUNNER listing and the only endpoint stating the window a model
      # is actually being served with; `model_metadata?` is `/api/show`, the
      # GGUF's TRAINED maximum, a different and larger number reached eagerly at
      # launch. Both happen to follow locality today, and they are written as
      # two definitions rather than one alias so a host that answers one and not
      # the other needs no untangling first.
      #
      # == One key decides five answers
      #
      # `local?` is DEFINED as `api_key.nil?`, so `api_base`, `request_timeout`,
      # `max_retries` and both probe predicates all follow credential-presence.
      # That is a real narrowing, and worth meeting here rather than discovering:
      # an authenticated loopback proxy, or a bearer-fronted remote self-hosted
      # ollama that really does serve `/api/ps`, is now unrepresentable. A third
      # arm like that wants a member saying which host this is, not another
      # branch on the key.
      #
      # == What still carries the key, and what no longer does
      #
      # `#inspect`, `#to_s`, `#pretty_print`, `#to_h`, `#deconstruct_keys` and
      # `#deconstruct` are redacted -- `Data` opens BOTH destructuring doors and
      # closing one leaves `case dep in [key, _]` binding the live value. And
      # `#instance_variables` hides the memoized header Hash from an inspector
      # that walks ivars rather than calling a printer.
      #
      # What no override covers is a WHOLE-OBJECT serialiser or the PUBLIC
      # `api_key` READER that {#apply} needs. `Marshal.dump` and `YAML.dump`
      # both emit the credential -- they read the members, not the printers --
      # and `have_attributes(api_key: ...)` renders the live value into a
      # failure message, measured on both this shape and the two-class one it
      # replaced. The same holds once a credential has LEFT the object:
      # `Transport#headers` returns a plain Hash, and no override can redact a
      # returned value a caller already holds. So the rule is about callers: a
      # spec asserting on a deployment's `api_key` or on transport headers must
      # use a literal fake key, and nothing may serialise a whole deployment.
      # {Tool::Bounds::Overrun} carries the same shape for the same reason.
      #
      # The LIVE path is `config.ollama_api_key`, written by {#apply}: the
      # {Transport} builds the wire header from it, and this value's own
      # `#headers` is a DECLARATION a spec checks the transport against.
      #
      # `Marshal.load(Marshal.dump(deployment))` raises `FrozenError` on BOTH
      # arms, because the header Hash -- `NO_AUTHORIZATION` on the loopback one
      # -- is assigned before `super` freezes the value, and Marshal's
      # allocate-then-restore order cannot reproduce that. The memberless
      # pre-merge loopback arm round-tripped; this one does not. No live path
      # marshals a deployment, and `dump` alone still succeeds carrying the key,
      # so a `FrozenError` is not a guard -- it is recorded so anything sending
      # one across a fork or a Ractor copy finds the reason here.
      #
      # The split into a bare `Data.define` and this reopen is the
      # constant-scoping trap, and the docstring sits on the reopen because YARD
      # keeps only that one.
      class Deployment
        # Refused at CONSTRUCTION because the wrong value is not wrong in a way
        # anything downstream can notice: `Configuration`'s generated setter
        # blanks a whitespace-only String to nil, so a key refused only there
        # has already become an `Authorization: Bearer ` with nothing after it,
        # and the operator learns about it as a 401 from somebody else's server.
        #
        # A {Lain::Error} so the exe's `rescue Lain::Error` maps it rather than
        # dumping a trace that names an internal collaborator.
        class MissingAPIKey < Error; end

        # A CONSTANT rather than a `{}.freeze` per call, so `#headers` hands
        # back the same object every time on the loopback arm too.
        NO_AUTHORIZATION = {}.freeze

        # WIRE-LEVEL FACTS ONLY, and identical on both arms, which is the point
        # of the cut: same encoder, same decoder, same wire, so the only
        # variables that moved are hosted-ness and model class. NDJSON and the
        # native `format` field are true of every model this endpoint serves.
        #
        # `:thinking` is NOT, and used to be. It is a property of the model
        # file, measured true for some of one server's models and false for
        # others, so a provider-wide claim here was a lie in the one subsystem
        # built to catch them. {ModelCapabilities} answers it per model off
        # `/api/show`, and there is one source for the fact rather than two.
        #
        # `:prompt_caching` stays absent for its own reason: ollama's pricing
        # meters "cached input tokens" separately, which is suggestive and is
        # not evidence, and the native response carries only a flat
        # `prompt_eval_count`.
        CAPABILITIES = %i[streaming structured_output].freeze

        # The loopback envelope, unchanged. 300s is not generosity: this is the
        # one arm whose honest shape is a model thinking for six minutes, and
        # every ollama measurement already recorded is denominated in it.
        LOCAL_REQUEST_TIMEOUT = 300
        LOCAL_MAX_RETRIES = 3

        # The cloud base for the same native endpoints -- not the `/v1/...`
        # OpenAI-compat surface, which is a different wire.
        CLOUD_API_BASE = "https://ollama.com"

        # NOT the loopback 300s/3. A metered hosted endpoint that has said
        # nothing for two minutes is rate-limited or down, and against a plan
        # with two rolling quotas a 429 is the ordinary case rather than the
        # exception, so this arm trades patience for attempts.
        CLOUD_REQUEST_TIMEOUT = 120
        CLOUD_MAX_RETRIES = 5

        # Named in every refusal because it is what a human sets, paired with
        # where a key comes from because a refusal naming neither sends them
        # looking.
        API_KEY_ENV_KEY = "OLLAMA_API_KEY"
        KEY_SOURCE = "https://ollama.com/settings/keys"

        # `String#strip` is not enough, and the gap is not theoretical: strip
        # removes ASCII whitespace and NUL but NOT U+00A0, so a key copied out
        # of the very settings page {KEY_SOURCE} names can be non-breaking space
        # only, pass a `strip.empty?` check, and reach the wire as a bare
        # `Bearer`. `[[:space:]]` is Unicode-aware and covers both that and the
        # trailing newline a key read from a file carries.
        SURROUNDING_SPACE = /\A[[:space:]]+|[[:space:]]+\z/

        # NEITHER message may quote the value. A refusal that echoed the key
        # would move the leak out of the adapter's `ArgumentError` and into our
        # own exception -- worse, because ours is the one callers are told to
        # rescue, log and report, and it would defeat every redaction guard
        # below from inside.
        #
        # Interpolated, so `frozen_string_literal` does not reach them and the
        # `.freeze` is load-bearing rather than decorative.
        BLANK_DIAGNOSIS = "#{API_KEY_ENV_KEY} holds only whitespace, so there is no key in it " \
                          "(a non-breaking space pasted from a web page looks identical to a " \
                          "real character)".freeze

        UNUSABLE_DIAGNOSIS = "#{API_KEY_ENV_KEY} holds a line break or control character, which " \
                             "an HTTP header field value cannot carry (a key copied from a " \
                             "soft-wrapped page, or read from a CRLF file, carries one " \
                             "invisibly). Its value is withheld here because it is a live " \
                             "credential".freeze

        # A width belongs to a metered plan, and the loopback arm declares nil
        # rather than 1 so `Provider::Admission.build`'s locality rule stays in
        # charge. Refused rather than dropped, because a keyword a constructor
        # accepts and then ignores is how a caller's mistake becomes invisible
        # at the one site that could have caught it.
        LOCAL_STATES_NO_WIDTH = "a deployment holding no api key is the loopback arm, which " \
                                "declares no admission width (Provider::Admission.build answers " \
                                "one for a local endpoint). Clearing a hosted deployment's key " \
                                "with #with reaches here too: build Deployment.local instead"

        # One concurrent model is what the Free plan permits, so it is the only
        # default that is safe on every plan.
        DEFAULT_ADMISSION_WIDTH = 1

        # Env, not a flag: the plan's width cannot be inferred from the API, and
        # every other admission width in lain is already set this way
        # (`Provider::Admission::ENV_KEY`). A per-endpoint key rather than that
        # process-wide one because raising the shared number to 3 for the cloud
        # arm would also raise the LOOPBACK arm off 1 and re-open the
        # one-slot-server starvation admission was built for.
        CONCURRENCY_ENV_KEY = "LAIN_OLLAMA_CLOUD_CONCURRENCY"

        # What every printer, walker and destructuring door hands out in place
        # of the key. Visible rather than silent, so a reader of a rendered
        # deployment knows a value was withheld instead of reading a blank.
        REDACTED = "[REDACTED]"

        class << self
          # @return [Deployment] the loopback arm, holding no credential
          def local = new

          # nil is refused HERE and not in the constructor, because a bare
          # `Deployment.new` carrying no key IS the loopback arm -- only a
          # caller that asked for the cloud can be told its key is missing.
          #
          # @param api_key [String] the subscription key
          # @param admission_width [Integer, String, nil] concurrent round trips
          #   this plan permits, or nil to read {CONCURRENCY_ENV_KEY}
          # @return [Deployment] the hosted arm
          # @raise [MissingAPIKey] on any key a header cannot carry
          def cloud(api_key:, admission_width: nil)
            raise MissingAPIKey, refusal(api_key) if api_key.nil?

            new(api_key:, admission_width:)
          end

          # THE ONE DEFINITION OF BLANK in this file, so {SURROUNDING_SPACE}'s
          # Unicode argument applies to both callers rather than to whichever of
          # them remembered it.
          #
          # @param value [Object] anything a caller or an env var offered
          # @return [String] the value with surrounding whitespace removed
          def trim(value) = value.to_s.gsub(SURROUNDING_SPACE, "")

          # Loud on a typo: a misspelt width that silently meant 1 would look
          # exactly like admission working. Unlike
          # {Provider::Admission::ENV_KEY}, `0` is refused too -- there it means
          # "unbounded", which is not a thing to ask of a plan that counts
          # concurrent models.
          #
          # Base 10 EXPLICITLY: a bare `Integer("0x10")` answers 16, which is
          # not what anyone typing a concurrency limit meant. An Integer passed
          # directly is taken as given, since `Integer(3, 10)` raises -- a base
          # may only be supplied for a String.
          #
          # @param declared [Integer, String, nil] an explicit width, or nil to
          #   read {CONCURRENCY_ENV_KEY}
          # @return [Integer] a width of at least 1
          # @raise [Lain::Error] on a non-integer, a hex or decimal literal, or
          #   anything less than 1
          def width(declared)
            raw = declared || ENV.fetch(CONCURRENCY_ENV_KEY, nil)
            return DEFAULT_ADMISSION_WIDTH if raw.nil? || trim(raw).empty?

            positive(raw)
          end

          # "is not set" is a claim about the environment, false for three of
          # the four ways a key can be unusable: telling an operator who can SEE
          # a value in `echo $OLLAMA_API_KEY` that the variable is unset sends
          # them to look in the wrong place. Every branch still names the
          # variable and where a key comes from.
          #
          # @param api_key [Object] the value that could not be a credential
          # @return [String] a refusal quoting no part of it
          def refusal(api_key)
            "#{diagnosis(api_key)}; Ollama Cloud needs an API key. Create one at #{KEY_SOURCE}"
          end

          private

          def positive(raw)
            parsed = raw.is_a?(Integer) ? raw : Integer(String(raw), 10)
            raise ArgumentError unless parsed.positive?

            parsed
          rescue ArgumentError, TypeError
            raise Error, "#{CONCURRENCY_ENV_KEY}=#{raw.inspect} is not an integer >= 1 " \
                         "(it is the number of models your plan lets you run at once)"
          end

          def diagnosis(api_key)
            return "#{API_KEY_ENV_KEY} is not set" if api_key.nil?
            return "#{API_KEY_ENV_KEY} is #{api_key.class}, not a String key" unless api_key.is_a?(String)
            return BLANK_DIAGNOSIS if trim(api_key).empty?

            UNUSABLE_DIAGNOSIS
          end
        end

        # The header Hash is built ONCE, before `super` freezes the value, and
        # handed back by identity. Rebuilt per call it would be a fresh unfrozen
        # Hash reachable from a frozen object, and `Ractor.shareable?` would
        # answer false.
        #
        # THE KEY IS TRIMMED EXACTLY ONCE, and the trimmed value is what is both
        # stored and sent. Validating a trimmed copy and storing the raw one is
        # how `Bearer sk-real\n` reaches Net::HTTP, which raises
        # `ArgumentError: header field value cannot include CR/LF` from inside
        # the adapter, naming neither {API_KEY_ENV_KEY} nor a remedy.
        #
        # Every door runs through here, {.cloud} and `Data#with` alike, so there
        # is no construction that skips the refusal.
        def initialize(api_key: nil, admission_width: nil)
          key = api_key.nil? ? nil : credential(api_key)
          raise ArgumentError, LOCAL_STATES_NO_WIDTH if key.nil? && admission_width

          @headers = key.nil? ? NO_AUTHORIZATION : { "Authorization" => "Bearer #{key}".freeze }.freeze
          super(api_key: key, admission_width: key && self.class.width(admission_width))
        end

        # Read by identity, never rebuilt -- see {#initialize}.
        attr_reader :headers

        def api_base = local? ? Transport::DEFAULT_API_BASE : CLOUD_API_BASE

        def local? = api_key.nil?

        def capabilities = CAPABILITIES

        def cache_profile = CacheProfile::NO_CACHING

        def request_timeout = local? ? LOCAL_REQUEST_TIMEOUT : CLOUD_REQUEST_TIMEOUT

        def max_retries = local? ? LOCAL_MAX_RETRIES : CLOUD_MAX_RETRIES

        # `/api/ps` lists LOADED RUNNERS -- a concept a serverless host does not
        # have. Answering false is what stops `#context_window_tokens` making
        # the request at all, rather than making it and rescuing it.
        def runner_status? = local?

        # `/api/show` is reached eagerly at launch through `CLI::Backend#num_ctx`,
        # before the chronicle is even open. Whether it answers on `ollama.com`
        # is unverified, and a launch that fires a live request to find out is
        # the wrong place to learn.
        def model_metadata? = local?

        # A COMPLETE POSITION, written unconditionally -- every field, every
        # time -- so a configuration always describes exactly one deployment no
        # matter what ran before it. A partial write is how one arm's endpoint
        # ends up beside another's credential, and the dangerous direction is
        # not hypothetical: the hosted arm's Bearer left on a loopback base is
        # sent, in plaintext, to whatever holds port 11434. The loopback arm's
        # nil key is what CLEARS it.
        #
        # `--api-base` is deliberately NOT honoured here, because this object
        # cannot tell an operator's flag from the previous deployment's write.
        # Only the provider knows whether `api_base:` was passed, so it applies
        # the deployment first and re-applies the flag afterwards.
        #
        # @param config [Provider::HTTP::Configuration]
        # @return [Provider::HTTP::Configuration] the same object, so a caller
        #   can keep composing
        def apply(config)
          config.ollama_api_base = api_base
          config.ollama_api_key = api_key
          config.request_timeout = request_timeout
          config.max_retries = max_retries
          config
        end

        # Never the key. A crashed example prints its subject and `Data` renders
        # every member, so the default would put a live credential into the
        # suite's output.
        def inspect = "#<data #{self.class} api_key=#{shown_key.inspect} admission_width=#{admission_width.inspect}>"
        alias to_s inspect

        # An inspector that WALKS INSTANCE VARIABLES reaches the memoized header
        # Hash without going through {#inspect}: super_diff 0.19.0 does exactly
        # that, rendering `@headers={"Authorization" => "Bearer <live key>"}`
        # into a failure message and from there into a CI log. The redaction has
        # to cover the walkers, not just the printers, because there is no
        # `#inspect` in that path to override.
        def instance_variables = super - %i[@headers]

        # `pp` walks members itself rather than calling `#inspect`.
        def pretty_print(printer) = printer.text(inspect)

        # `Data` supplies this for free, and a Journal record is a Hash -- so
        # the free version is the one that would carry a live key into the
        # NDJSON. Redacting it costs no value semantics: `==`, `#hash` and
        # `#with` read the members directly rather than through here.
        #
        # @param block [Proc] the pair-rewriting block `Hash#to_h` takes
        # @return [Hash] both members, the credential withheld
        def to_h(&block)
          shown = { api_key: shown_key, admission_width: }
          block ? shown.to_h(&block) : shown
        end

        # Pattern matching is the other door `Data` opens, and it is TWO doors:
        # `in {api_key:}` reads this one and `in [key, _]` reads {#deconstruct}.
        # Closing only the hash form leaves the array form binding the live
        # value.
        def deconstruct_keys(keys) = keys.nil? ? to_h : to_h.slice(*keys)

        def deconstruct = to_h.values

        private

        # nil on the loopback arm, because it holds no key and saying it holds a
        # withheld one would be a lie in the other direction.
        def shown_key = local? ? nil : REDACTED

        # {Transport::UNUSABLE_IN_HEADER} rather than a second copy of the
        # regex: this refusal is a POLICY one and belongs here, but it has no
        # business restating an HTTP rule. A non-String is REFUSED rather than
        # coerced -- `to_s` would put `Bearer {a: 1}` on the wire and earn a 401
        # that names nothing.
        #
        # Copied rather than frozen in place: freezing a caller's String is a
        # side effect on an object that is not ours.
        def credential(api_key)
          trimmed = api_key.is_a?(String) ? self.class.trim(api_key) : nil
          raise MissingAPIKey, self.class.refusal(api_key) if unusable?(trimmed)

          trimmed.freeze
        end

        def unusable?(trimmed)
          trimmed.nil? || trimmed.empty? || trimmed.match?(Transport::UNUSABLE_IN_HEADER)
        end
      end
    end
  end
end
