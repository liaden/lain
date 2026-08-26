# frozen_string_literal: true

require "uri"

module Lain
  module CLI
    class Backend
      # An `--api-base` that WOULD work and must not be used. Separate from
      # {InvalidEndpoint}, which refuses a URL nothing could send a request to;
      # this refuses a URL something could send a SUBSCRIPTION KEY to in the
      # clear. {Endpoint} validates shape and knows nothing about which arm is
      # asking, so the refusal lives beside the object that does know.
      class PlaintextEndpoint < Error; end

      # THE WHOLE OF WHAT THE TWO OLLAMA ARMS MEAN: which deployment a run
      # dials, where its credential comes from, which model it defaults to, and
      # the two refusals that have to fire before the chronicle opens. Its own
      # object because "where does a credential come from" is not something a
      # flag bag should decide.
      #
      # == Why a provider NAME rather than a `--cloud` boolean
      #
      # `lain bench arms` and `lain bench record` build their {Backend} from
      # closed literal maps (`ARMS_FLAGS`, `RECORD_FLAGS` in `exe/lain`), and
      # both forward `provider:`. A boolean carries no key in either map, so the
      # bench would silently drop it and sweep the local arm instead -- and the
      # bench case is the whole reason the cloud arm exists.
      #
      # == Both refusals fire at CONSTRUCTION, and their order is load-bearing
      #
      # {#provider} is lazy and is not reached by every command, so a refusal
      # that waited for it would depend on which collaborator a given run
      # happened to build.
      #
      # The PLAINTEXT refusal goes first. It is a claim about the flag the
      # operator just typed, and it must not depend on whether a key happens to
      # be exported: the same argv refused for one reason on a box with a key
      # and another reason on a box without is how somebody fixes the wrong
      # thing first.
      #
      # == The key is READ here and VALIDATED there
      #
      # {Provider::Ollama.cloud} requires `api_key:` and deliberately does not
      # reach for the environment, so the CLI -- the caller that looked the
      # variable up -- is the one {Deployment::Cloud}'s named refusal reaches.
      # This class does the lookup and owns none of the diagnosis: "unset",
      # "whitespace only" and "carries a control character" are three different
      # messages, and they live on the deployment beside the header that would
      # otherwise carry the damage.
      #
      # THE KEY IS NEVER HELD. The eager refusal is a PROBE -- it builds a
      # {Deployment::Cloud}, lets it refuse, and drops it -- and {#provider}
      # reads the variable again when it really builds one. What that buys is
      # that no CLI object holds a live credential for the length of a run:
      # `Deployment::Cloud#to_h` is unredacted and cannot be while `api_key` is
      # a public reader, so the safest place for one is nowhere. That sentence
      # is PINNED, not merely asserted: an example walks `#instance_variables`
      # and fails on any of them holding the key. Stated in prose it survived a
      # planted `@held_key = ENV.fetch(...)` with the whole suite green.
      #
      # == `--api-base` belongs to the arm the operator pointed it at
      #
      # There is ONE `--api-base` flag and TWO tiers that can be ollama, and
      # originally the CHAT's base was handed to a tier built for the
      # SUMMARIZER's name. `--provider ollama --api-base https://internal.example
      # --summarizer-provider ollama-cloud` therefore built a summarizer whose
      # transport sent `OLLAMA_API_KEY` as a bearer token to `internal.example`
      # -- a host named by the other arm's flag -- with nothing refusing,
      # because every value involved was valid on its own. A subscription key
      # sent somewhere the operator did not choose for it is an exfiltrated key,
      # and plaintext is only the loudest way to arrive there.
      #
      # {.claims_base?} owns which arm it belongs to. Backend applies that rule
      # and passes only the base that survives it, so this class never holds one
      # it will not use.
      class OllamaTier
        # As `--provider` spells them. {Backend}'s two `case` arms key off
        # {NAMES}, so a rename is one edit rather than three places to leave
        # disagreeing.
        LOCAL = "ollama"
        CLOUD = "ollama-cloud"
        NAMES = [LOCAL, CLOUD].freeze

        # WHICH flag selected this tier. A field rather than a literal in the
        # message, for {Endpoint}'s stated reason, so a refusal can never name a
        # flag the operator did not set.
        CHAT_FLAG = "--provider"
        SUMMARIZER_FLAG = "--summarizer-provider"

        class << self
          # WHICH tier `--api-base` belongs to, and the rule is NOT "the tier
          # whose name is the chat's". That answer was too broad, because
          # {Backend::DEFAULT_SUMMARIZER_PROVIDER} is "ollama": under it,
          # `--provider anthropic --api-base http://my-ollama:11434` stopped
          # reaching the summarizer that flag was obviously for and the
          # summarizer quietly ran against loopback -- a silent wrong host, on
          # the LOCAL path this arm promised not to touch.
          #
          # The rule is: the base reaches an ollama tier when that tier is the
          # ONLY ollama-shaped arm the operator could have meant. So either the
          # tier IS what `--provider` names, or `--provider` names nothing
          # ollama-shaped at all and the summarizer is the only candidate left.
          # Five cases, all pinned in the specs:
          #
          #   chat            summarizer        reaches it?
          #   ollama          ollama (default)  yes -- one arm, and it is the chat's
          #   anthropic       ollama (default)  yes -- the only ollama arm there is
          #   nil / ""        ollama (default)  yes -- same, for a hand-built Backend
          #   ollama          ollama-cloud      no  -- the chat's, and it has it
          #   ollama-cloud    ollama (default)  no  -- likewise; the base is the cloud arm's
          #
          # The two "no" rows lose nothing: in both, `--provider` names an
          # ollama arm and that arm receives the base. This is a rule about
          # WHOSE the base is, not a refusal.
          #
          # @param name [String] the tier's own provider name
          # @param chat_provider [String, nil] whatever `--provider` said
          # @return [Boolean]
          def claims_base?(name, chat_provider)
            name == chat_provider || !NAMES.include?(chat_provider)
          end

          # Shared with {Backend#anthropic_provider}: one definition, so the two
          # arms cannot come to disagree about what a tier's own flag is called.
          def flag_for(chat:) = chat ? CHAT_FLAG : SUMMARIZER_FLAG
        end

        # The flag the base itself came from, which is neither of the above.
        ENDPOINT_FLAG = "--api-base"

        API_KEY_ENV_KEY = Provider::Ollama::Deployment::Cloud::API_KEY_ENV_KEY

        # NOT the local default `qwen3:4b`, which does not exist on the cloud at
        # all, so inheriting it would make a bare `--provider ollama-cloud` a
        # 404 rather than a session. `gpt-oss:20b-cloud` is the smallest
        # published cloud tag and -- the part that matters for a default -- a
        # KEY IN {ContextWindow::CLOUD_WINDOWS}. A default matching no row there
        # would fall to the GUESSED 8,192 fallback and have a fresh session
        # compacting on turn one against a window it is nowhere near; a spec
        # pins the membership, not just the string.
        CLOUD_DEFAULT_MODEL = "gpt-oss:20b-cloud"

        # @param name [String] the provider name this tier is being built for
        # @param chat [Boolean] whether this is the CHAT's own arm (`--provider`)
        #   rather than the summarizer tier's (`--summarizer-provider`). It
        #   decides ONE thing: which flag a refusal names. It does NOT decide
        #   `--api-base` -- {.claims_base?} records what that cost.
        # @param api_base [String, nil] the base that applies to THIS arm,
        #   already decided by {.claims_base?}. Taken as given and never
        #   discarded: a keyword a constructor accepts and then ignores is how
        #   the caller's mistake becomes invisible at the one site that could
        #   have caught it, so the filtering happens before the call, not here.
        # @raise [PlaintextEndpoint] on a cloud arm pointed at http
        # @raise [InvalidEndpoint] on a base that is not a usable URL at all
        # @raise [Provider::Ollama::Deployment::MissingAPIKey] on a cloud arm
        #   with no usable {API_KEY_ENV_KEY}
        def initialize(name:, chat: true, api_base: nil)
          @name = name
          @chat = chat
          @api_base = api_base
          refuse_unusable_cloud if cloud?
        end

        def cloud? = @name == CLOUD

        # @param channel [Lain::Channel] where retries and stalls are narrated
        # @param queue [Boolean] the caller's willingness to wait for a slot
        # @param journal [#<<] where a {Telemetry::ProviderWait} lands
        # @param spool [#open_frame] the run's response WAL. Forwarded to
        #   BOTH arms, not just the metered one: a local arm that silently
        #   discarded it would make `lain resume` answer differently depending
        #   on which ollama the session dialled. A real Null Object rather than
        #   nil, matching {Backend#provider}'s own default, so this arm states a
        #   spool either way and nothing downstream coalesces.
        # @return [Provider::Ollama] dialling whichever ollama this arm names
        def provider(channel:, queue:, journal:, spool: Provider::Spool::Null.new)
          return Provider::Ollama.local(api_base: @api_base, channel:, queue:, journal:, spool:) unless cloud?

          naming_the_flag do
            Provider::Ollama.cloud(api_key: key, api_base: @api_base, channel:, queue:, journal:, spool:)
          end
        end

        # A CLASS method, and deliberately not an instance one: which model an
        # arm defaults to is a pure function of its NAME. Asking an instance
        # would mean {Backend#model} -- read per turn by {Backend#context},
        # {WindowBook} and {Compaction::Source#window_for} -- building a tier
        # and a {Deployment::Cloud}, re-reading ENV, and being able to raise
        # {Deployment::MissingAPIKey} from any of those call sites.
        #
        # @param name [String] a name in {NAMES}
        # @return [String] the model a run on that arm gets with no `--model`
        def self.default_model(name) = name == CLOUD ? CLOUD_DEFAULT_MODEL : Provider::Ollama::DEFAULT_MODEL

        private

        def key = ENV.fetch(API_KEY_ENV_KEY, nil)

        def flag = self.class.flag_for(chat: @chat)

        def refuse_unusable_cloud
          raise PlaintextEndpoint, plaintext_message unless secure_base?

          probe_credential
        end

        # Built and DROPPED: the constructor IS the refusal, and the class
        # docstring says why nothing here keeps what it hands back.
        def probe_credential = naming_the_flag { Provider::Ollama::Deployment::Cloud.new(api_key: key) }

        # The deployment's refusal names the VARIABLE but not which flag asked
        # for one, so an operator running `--provider anthropic
        # --summarizer-provider ollama-cloud` is told about a credential they do
        # not recognise requiring. ANNOTATED, never replaced -- same class, same
        # diagnosis, plus {#flag} -- so the deployment stays the one authority
        # on what is wrong with a key and this class only says who asked.
        #
        # This is also what keeps {#flag} honest: the plaintext refusal can only
        # be reached from the chat arm, so were this not here the field would
        # have one live value and a hardcoded literal would do.
        def naming_the_flag
          yield
        rescue Provider::Ollama::Deployment::MissingAPIKey => e
          raise e.class, "#{e.message}; #{flag} #{@name} is what asked for it"
        end

        # An unset `--api-base` means {Deployment::Cloud::API_BASE}, which is
        # https by construction.
        #
        # Through {Endpoint} FIRST. {Backend} has already run the value through
        # it, but this class has a documented public constructor, so a value can
        # arrive here having passed nothing -- and a bare `URI.parse("not a
        # url")` raises `URI::InvalidURIError`, which is not a {Lain::Error} and
        # so reaches the operator as a backtrace rather than as the flag they
        # got wrong.
        def secure_base?
          return true if @api_base.nil?

          URI.parse(Endpoint.new(flag: ENDPOINT_FLAG, value: @api_base).url).scheme == "https"
        end

        # Names the KEY, because a refusal that only said "https is required"
        # reads as pedantry rather than as "you are about to post your
        # subscription token in the clear". The escape hatch is named too: an
        # operator pointing at a plaintext proxy usually meant the local arm.
        def plaintext_message
          "#{ENDPOINT_FLAG} #{@api_base.inspect} is not https, and #{flag} #{CLOUD} sends " \
            "#{API_KEY_ENV_KEY} as a bearer token on every request; a subscription key sent in " \
            "plaintext is an exfiltrated key. Use an https base, or #{flag} #{LOCAL} for a " \
            "server you are already talking to over the loopback."
        end
      end
    end
  end
end
