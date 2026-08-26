# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      module Deployment
        # A cloud deployment built without a key. Refused at CONSTRUCTION
        # because the wrong value is not wrong in a way anything downstream can
        # notice: `Configuration`'s generated setter blanks a whitespace-only
        # String to nil, so a key refused only there has already become an
        # `Authorization: Bearer ` with nothing after it, and the operator
        # learns about it as a 401 from somebody else's server.
        #
        # A {Lain::Error} so the exe's `rescue Lain::Error` maps it rather than
        # dumping a trace that names an internal collaborator.
        class MissingAPIKey < Error; end

        Cloud = Data.define(:api_key, :admission_width)

        # Somebody else's ollama: the same native `/api/chat`, behind a bearer
        # token, metered by concurrency and quota.
        #
        # Deliberately NOT a subclass of {Local}: there is no value the two
        # agree about by nature, and a shared default would be a place for one
        # of them to be silently wrong.
        #
        # == What is declared, and what is refused
        #
        # The capability list is IDENTICAL to the local arm's, which is the
        # point of the cut -- same encoder, same decoder, same wire, so the only
        # variables that moved are hosted-ness and model class. It notably does
        # NOT include `:prompt_caching`: ollama's pricing meters "cached input
        # tokens" separately, which is suggestive and is not evidence, and the
        # native response carries only a flat `prompt_eval_count`, so this path
        # cannot demonstrate a cache hit at all.
        #
        # == Rate limits are left to faraday-retry, deliberately
        #
        # `rate_limit_reset_header` and `header_parser_block` are Configuration
        # knobs this deployment does not write. That is a DECISION: the header
        # vocabulary the native cloud path returns is unverified, and
        # faraday-retry already coalesces an unset knob to its own
        # `RateLimit-Reset` handling, so naming a header nobody has seen would
        # replace a working default with a guess.
        #
        # == Which credential path is authoritative
        #
        # `config.ollama_api_key`, written by {#apply}, is the LIVE path:
        # {Transport} builds the wire header from it and
        # `Connection#provider_headers` asks the transport. This class's own
        # `#headers` is a DECLARATION, merged nowhere -- it says what the
        # transport's header must look like, and a spec checks the two agree.
        #
        # == What still carries the key in plaintext
        #
        # `#inspect`, `#to_s` and `#pretty_print` are redacted. `#to_h` and
        # `#deconstruct_keys` are NOT, and cannot be while `api_key` is a public
        # reader {#apply} needs -- that is inherent to `Data`. `to_h` is the one
        # that matters: it would carry a live key into the NDJSON Journal if a
        # deployment were ever journaled. Nothing journals one today; anything
        # that starts to must redact first.
        #
        # `Marshal.load(Marshal.dump(cloud))` raises `FrozenError`, because the
        # memoized header Hash is assigned before `super` freezes the value and
        # Marshal's allocate-then-restore order cannot reproduce that. No live
        # path marshals a deployment; recorded so anything sending one across a
        # fork or a Ractor copy finds the reason here.
        #
        # The split into a bare `Data.define` and this reopen is the
        # constant-scoping trap, and the docstring sits on the reopen because
        # YARD keeps only that one.
        class Cloud
          # The cloud base for the same native endpoints -- not the `/v1/...`
          # OpenAI-compat surface, which is a different wire.
          API_BASE = "https://ollama.com"

          # Named in the refusal because it is what a human sets, paired with
          # where a key comes from because a refusal naming neither sends them
          # looking.
          API_KEY_ENV_KEY = "OLLAMA_API_KEY"
          KEY_SOURCE = "https://ollama.com/settings/keys"

          # `String#strip` is not enough, and the gap is not theoretical: strip
          # removes ASCII whitespace and NUL but NOT U+00A0, so a key copied
          # out of the very settings page {KEY_SOURCE} names can be
          # non-breaking space only, pass a `strip.empty?` check, and reach the
          # wire as a bare `Bearer`. `[[:space:]]` is Unicode-aware and covers
          # both that and the trailing newline a key read from a file carries.
          SURROUNDING_SPACE = /\A[[:space:]]+|[[:space:]]+\z/

          # NEITHER message may quote the value. A refusal that echoed the key
          # would move the leak out of the adapter's `ArgumentError` and into
          # our own exception -- worse, because ours is the one callers are told
          # to rescue, log and report, and it would defeat the four redaction
          # guards from inside.
          #
          # Those guards cover this object. They do NOT cover a credential that
          # has already LEFT it: `Transport#headers` RETURNS a plain Hash, and
          # no override can redact a returned value once a caller holds it. A
          # failing expectation on `transport.headers` renders the live Bearer
          # -- measured, not supposed. Every spec asserting on those headers
          # uses a literal fake key, so the constraint is on whoever writes the
          # first spec that holds a REAL one.
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

          # Same list as {Local}: the cut on the provider axis is only clean
          # while these agree.
          CAPABILITIES = %i[streaming thinking structured_output].freeze

          # NOT the local arm's 300s/3. That envelope exists for a server
          # loading weights into VRAM and then thinking for six minutes; a
          # metered hosted endpoint that has said nothing for two minutes is
          # rate-limited or down, and against a plan with two rolling quotas a
          # 429 is the ordinary case rather than the exception. So this arm
          # trades patience for attempts.
          REQUEST_TIMEOUT = 120
          MAX_RETRIES = 5

          # One concurrent model is what the Free plan permits, so it is the
          # only default that is safe on every plan.
          DEFAULT_ADMISSION_WIDTH = 1

          # Env, not a flag: the plan's width cannot be inferred from the API,
          # and every other admission width in lain is already set this way
          # (`Provider::Admission::ENV_KEY`). A per-endpoint key rather than
          # that process-wide one because raising the shared number to 3 for
          # the cloud arm would also raise the LOCAL arm off 1 and re-open the
          # one-slot-server starvation admission was built for.
          CONCURRENCY_ENV_KEY = "LAIN_OLLAMA_CLOUD_CONCURRENCY"

          class << self
            # THE ONE DEFINITION OF BLANK in this file, so {SURROUNDING_SPACE}'s
            # Unicode argument applies to both callers rather than to whichever
            # of them remembered it.
            #
            # @param value [Object] anything a caller or an env var offered
            # @return [String] the value with surrounding whitespace removed
            def trim(value) = value.to_s.gsub(SURROUNDING_SPACE, "")

            # Loud on a typo: a misspelt width that silently meant 1 would look
            # exactly like admission working. Unlike
            # {Provider::Admission::ENV_KEY}, `0` is refused too -- there it
            # means "unbounded", which is not a thing to ask of a plan that
            # counts concurrent models.
            #
            # Base 10 EXPLICITLY: a bare `Integer("0x10")` answers 16, which is
            # not what anyone typing a concurrency limit meant. An Integer
            # passed directly is taken as given, since `Integer(3, 10)` raises
            # -- a base may only be supplied for a String.
            #
            # @param declared [Integer, String, nil] an explicit width, or nil
            #   to read {CONCURRENCY_ENV_KEY}
            # @return [Integer] a width of at least 1
            # @raise [Lain::Error] on a non-integer, a hex or decimal literal,
            #   or anything less than 1
            def width(declared)
              raw = declared || ENV.fetch(CONCURRENCY_ENV_KEY, nil)
              return DEFAULT_ADMISSION_WIDTH if raw.nil? || trim(raw).empty?

              positive(raw)
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
          end

          # The header Hash is built ONCE, before `super` freezes the value, and
          # handed back by identity. Rebuilt per call it would be a fresh
          # unfrozen Hash reachable from a frozen object, and
          # `Ractor.shareable?` would answer false.
          #
          # THE KEY IS STRIPPED EXACTLY ONCE, and the stripped value is what is
          # both stored and sent. Validating a stripped copy and storing the raw
          # one is how `Bearer sk-real\n` reaches Net::HTTP, which raises
          # `ArgumentError: header field value cannot include CR/LF` from inside
          # the adapter, naming neither {API_KEY_ENV_KEY} nor a remedy. It is
          # copied rather than frozen in place: freezing a caller's String is a
          # side effect on an object that is not ours.
          def initialize(api_key:, admission_width: nil)
            key = credential(api_key)
            raise MissingAPIKey, refusal(api_key) if key.nil?

            @headers = { "Authorization" => "Bearer #{key}".freeze }.freeze
            super(api_key: key, admission_width: self.class.width(admission_width))
          end

          # Read by identity, never rebuilt -- see {#initialize}.
          attr_reader :headers

          def api_base = API_BASE

          def local? = false

          def capabilities = CAPABILITIES

          def cache_profile = CacheProfile::NO_CACHING

          def request_timeout = REQUEST_TIMEOUT

          def max_retries = MAX_RETRIES

          # `/api/ps` lists LOADED RUNNERS -- a concept a serverless host does
          # not have. Answering false is what stops `#context_window_tokens`
          # making the request at all, rather than making it and rescuing it.
          def runner_status? = false

          # `/api/show` is reached eagerly at launch through
          # `CLI::Backend#num_ctx`, before the chronicle is even open. Whether
          # it answers on `ollama.com` is unverified, and a launch that fires a
          # live request to find out is the wrong place to learn.
          def model_metadata? = false

          # A COMPLETE POSITION, written unconditionally -- every field, every
          # time -- so a configuration always describes exactly one deployment
          # no matter what ran before it. A partial write is how one arm's
          # endpoint ends up beside another's credential, and the dangerous
          # direction is not hypothetical: this arm's Bearer left on a loopback
          # base is sent, in plaintext, to whatever holds port 11434.
          #
          # `--api-base` is deliberately NOT honoured here, because this object
          # cannot tell an operator's flag from the previous deployment's write.
          # Only the provider knows whether `api_base:` was passed, so it
          # applies the deployment first and re-applies the flag afterwards.
          #
          # @param config [Provider::HTTP::Configuration]
          # @return [Provider::HTTP::Configuration] the same object, so a
          #   caller can keep composing
          def apply(config)
            config.ollama_api_base = api_base
            config.ollama_api_key = api_key
            config.request_timeout = request_timeout
            config.max_retries = max_retries
            config
          end

          # Never the key. A crashed example prints its subject and `Data`
          # renders every member, so the default would put a live credential
          # into the suite's output.
          def inspect = "#<data #{self.class} api_key=[REDACTED] admission_width=#{admission_width}>"
          alias to_s inspect

          # An inspector that WALKS INSTANCE VARIABLES reaches the memoized
          # header Hash without going through {#inspect}: super_diff 0.19.0 does
          # exactly that, rendering `@headers={"Authorization" => "Bearer <live
          # key>"}` into a failure message and from there into a CI log. The
          # redaction has to cover the walkers, not just the printers, because
          # there is no `#inspect` in that path to override -- and `pp` is the
          # same shape, walking members itself rather than calling `#inspect`.
          #
          # `api_key` needs no such treatment: it is a Data member, not an ivar.
          def instance_variables = super - %i[@headers]

          def pretty_print(printer) = printer.text(inspect)

          private

          # nil for anything that cannot be a credential, so {#initialize} has
          # exactly one question to ask. A non-String is REFUSED rather than
          # coerced: `to_s` would put `Bearer {a: 1}` on the wire and earn a 401
          # that names nothing. {Transport::UNUSABLE_IN_HEADER} rather than a
          # second copy of the regex -- this refusal is a POLICY one and belongs
          # here, but it has no business restating an HTTP rule.
          def credential(api_key)
            return nil unless api_key.is_a?(String)

            trimmed = self.class.trim(api_key)
            return nil if trimmed.empty? || trimmed.match?(Transport::UNUSABLE_IN_HEADER)

            trimmed.freeze
          end

          # "is not set" is a claim about the environment, false for two of the
          # three ways a key can be unusable: telling an operator who can SEE a
          # value in `echo $OLLAMA_API_KEY` that the variable is unset sends
          # them to look in the wrong place. Every branch still names the
          # variable and where a key comes from.
          def refusal(api_key)
            "#{diagnosis(api_key)}; Ollama Cloud needs an API key. Create one at #{KEY_SOURCE}"
          end

          def diagnosis(api_key)
            return "#{API_KEY_ENV_KEY} is not set" if api_key.nil?
            return "#{API_KEY_ENV_KEY} is #{api_key.class}, not a String key" unless api_key.is_a?(String)
            return BLANK_DIAGNOSIS if self.class.trim(api_key).empty?

            UNUSABLE_DIAGNOSIS
          end
        end
      end
    end
  end
end
