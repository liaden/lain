# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module Lain
  module Oracle
    # The secret-read arm: "may this parked read of a file holding sensitive
    # regions be released?" -- asked of a LOCAL model (or, opted in, a cloud one
    # behind a lain gateway; see below), beside the human, about a
    # call that is already blocking.
    #
    # UNLIKE {MemorySave}, nothing here sits on the live tool-dispatch path. Its
    # one caller is {Approval::Parked::SecretSurface}, a QUEUE surface racing the human
    # for pendings {Approval::Parked::Queue} has already parked. A surface that never
    # answers costs nothing, because the fail-closed clock denies whatever nobody
    # decided.
    #
    # == The provider is CONSTRUCTED here, and that is the security property
    #
    # {.tier} builds {Provider::Ollama} directly and takes no seam that could
    # replace it -- not `--provider`, not `--summarizer-provider`, not
    # `--api-base`, not {Oracle::Router}. `CLI::Backend#summarizer_provider` looks
    # like the reusable precedent and is precisely the wrong one: it resolves a
    # USER-SETTABLE knob over `anthropic, ollama, ollama-cloud`, so a copy of it would
    # let `--summarizer-provider anthropic` ship the candidate secret's PATH to a
    # remote model. No api_base is passed either: `Backend#provider` hands
    # `--api-base` straight to the ollama arm, which would redirect the "local"
    # judge at any host a flag names.
    #
    # The accurate word is LOOPBACK, not "no api_base". What makes the round trip
    # un-exfiltratable is that the resolved endpoint is `http://localhost:11434`
    # ({Provider::Ollama::Transport::DEFAULT_API_BASE}) and that Ruby's
    # `URI::Generic#find_proxy` exempts loopback from `http_proxy`/`HTTP_PROXY`,
    # verified live against five proxy variables. An `ollama_api_base` resolving
    # off-loopback would put the question on the wire with the proxy honoured, so
    # the two halves stand or fall together.
    #
    # == What the question may contain
    #
    # The path, the tool, and how MANY regions are outstanding. Never a region's
    # bytes: putting the value in the question would disclose it to the very model
    # the gate exists to withhold it from ({Approval::Parked::Queue::Outstanding#preamble}
    # states the same rule one surface over). The judgement is therefore about a
    # PATH, which is what makes a small local model a defensible judge at all.
    #
    # The PATH is disclosed, and that is a real edge: a credential spelled into a
    # FILENAME reaches the judge and the journal in the clear. It is inherent to
    # naming the file at all -- the human prompt and the editor row both print
    # it -- so it is a property of the whole boundary, not of this arm. Read
    # "never a region's bytes" as exactly that and no wider.
    #
    # == Confidence is evidence, not control flow
    #
    # The schema's `confidence` is a local model's SELF-REPORT: a rank, not a
    # probability. It is journaled on every answer so
    # {Approval::Parked::SecretSurface::DEFAULT_THRESHOLD} can be set from measurement
    # rather than asserted. Nothing here reads it; the surface owns the threshold,
    # because routing is the surface's job.
    #
    # == The cloud tier, and why loopback is not enough for it
    #
    # {.cloud_tier} asks a hosted model, and only through a lain gateway the
    # human runs (`lain gateway`), which shows them every request before it
    # leaves. A loopback address proves nothing on its own: a local ollama on
    # 127.0.0.1:11434 forwards a `:cloud` tag to ollama.com with nobody asked.
    # So before every question the listener must answer a fresh nonce at
    # {Gateway::IDENTITY_PATH} with its HMAC under the token the gateway left in
    # its {Gateway::TokenFile}, which the token never crosses the wire to do. That shows the
    # listener holds the token, or can reach something that does; it cannot
    # show nothing sits between the two. The local tier refuses a cloud model
    # name outright.
    module SecretRead
      # The endpoint named for the cloud tier is not a proven lain gateway, or a
      # cloud model was named for the local tier.
      class NotAGateway < Error; end

      # Both spellings ollama gives a model it forwards to its own cloud, read
      # after {.cloud_model?} strips and downcases the name.
      CLOUD_MODEL = /(?::|-)cloud\z/

      # Where the gateway serves each kind of model, as its identity names them.
      OLLAMA_PATH = "/api/chat"
      ANTHROPIC_PATH = "/v1/messages"

      # The gateway puts its own credential on the forward, so the chat's key
      # never needs to reach even a loopback listener.
      GATEWAY_KEY = "via-lain-gateway"

      ONLY_THROUGH = "the cloud oracle reaches a model only through a loopback lain gateway"
      LOCAL_CLOUD_MODEL = "%<model>p is a cloud model, which a local ollama forwards with nobody asked; " \
                          "use --secret-oracle cloud with --gateway set to the URL `lain gateway` prints"
      GUARDS_ONLY = "the secret oracle takes only the egress guard as http middleware: any other entry " \
                    "could move the endpoint it asks"

      # @param model [String]
      # @return [Boolean] whether a local ollama would forward the model to its cloud
      def self.cloud_model?(model) = model.to_s.strip.downcase.match?(CLOUD_MODEL)

      # @param model [String]
      # @return [String] the gateway path the cloud tier asks that model at
      def self.gateway_path(model) = cloud_model?(model) ? OLLAMA_PATH : ANTHROPIC_PATH
      # The one spelling of the three words a verdict may be. Named once and
      # read by the field description, the inclusion check and the question
      # template below, rather than repeated at each -- three copies of
      # `%w[approve deny defer]` is the shape that drifts.
      VERDICTS = %w[approve deny defer].freeze

      # "approve, deny, or defer", built once from {VERDICTS} for the same
      # reason: the prose in the description, the validator's message and the
      # template all want the Oxford-comma sentence, not the bare Array.
      VERDICT_SENTENCE = "#{VERDICTS[0..-2].join(", ")}, or #{VERDICTS.last}".freeze

      # `verdict` is the one field that decides anything; `confidence` is what a
      # threshold is applied to; `reason` rides along for the journal.
      SCHEMA = Class.new(Tool::Input) do
        field :verdict, :string, required: true,
                                 description: "#{VERDICT_SENTENCE} -- defer whenever unsure"
        field :confidence, :float, required: true,
                                   description: "0.0 to 1.0: how certain this verdict is"
        field :reason, :string, description: "one-line justification, for the journal"

        # A local model has been measured sending schema-valid nonsense past
        # both fields -- a confidence of 90 where the schema means 0.0 to 1.0,
        # and a verdict outside the three words asked for. Nothing downstream
        # re-checks either: {Approval::Parked::SecretSurface#confident?} compares
        # `confidence` straight against a threshold, so an unconstrained 90
        # would outrank every real verdict forever, and an unrecognised
        # `verdict` would merely fall through `#settle`'s two `if`s unnoticed
        # rather than say so.
        #
        # `verdict` is normalized -- stripped, downcased -- ON ASSIGNMENT,
        # before the inclusion check below ever runs. Skipping that would put
        # this validator at odds with the comparison it exists to protect:
        # {Approval::Parked::SecretSurface#confident?} already tolerates case and
        # whitespace (`answer.verdict.to_s.strip.downcase == verdict`), so an
        # exact inclusion check would hard-reject "Approve" or "approve\n" as
        # an oracle fault even though the surface would have matched either
        # correctly. Normalizing here, not there, is what makes the STORED
        # answer canonical rather than merely tolerated at one call site.
        def verdict=(value)
          super(value.nil? ? value : value.to_s.strip.downcase)
        end

        validates :verdict, inclusion: { in: VERDICTS, message: "must be #{VERDICT_SENTENCE}" }
        validates :confidence, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 },
                               allow_nil: true
      end

      # Three slots, and the absence of a fourth is the point (see the module
      # header). The instruction leans on DEFER twice, because an ambiguous answer
      # here releases a secret rather than merely wasting a turn.
      #
      # THE LAST LINE IS NOT DECORATION. {Oracle::Model::JsonDecoder} demands a
      # JSON object, and a template that asks only for a verdict gets exactly what
      # it asked for: measured against real ollama on {.tier}'s own
      # `DEFAULT_MODEL`, "Answer approve, deny, or defer" returned the bare word
      # `deny` and raised {Oracle::UndecodableAnswer} 4 times out of 4, at 8-10s
      # each. The model was RIGHT and the arm was dead -- every pending fell to
      # the clock, and since a fault journals no {Telemetry::OracleAnswer} the
      # confidence data the threshold is calibrated from never accrued either. No
      # other template in the repo says "JSON".
      TEMPLATE = <<~ERB
        A tool call is parked at an approval gate. It names one file, in which
        <%= render("region_count") %> sensitive region(s) have been found so far;
        0 means only the path is gated and the file has not been read.

        path: <%= render("path") %>
        tool: <%= render("tool") %>

        You are shown the path and the count, never the file's contents. Judge
        from the path alone. Answer approve only if a file at that path plainly
        holds no real secret -- a dependency lockfile, a checksum manifest,
        vendored third-party source. Answer deny if it plainly does -- a private
        key, a credential store, an environment file. Answer defer if you are
        unsure, and prefer defer: a human is already being asked this question,
        and deferring only leaves it to them.

        Reply with a JSON object and nothing else, in exactly this shape:
        {"verdict": "#{VERDICTS.join("|")}", "confidence": <your certainty, 0 to 1>, "reason": "one line"}
      ERB
                 .freeze

      # @param tier [Symbol] folded into the Definition's digest, so the same
      #   question answered by two tiers is two oracles at two addresses (see
      #   {PruneScoring.definition} for the same reasoning).
      # @return [Oracle::Definition]
      def self.definition(tier: :model)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end

      # The local tier, and the only construction of it. Every
      # answer is journaled before it reaches the caller, which is what accrues
      # the calibration data the threshold is set from.
      #
      # The parameter list is deliberately this short, and a spec pins it: a
      # `provider:`, `backend:` or `router:` keyword appearing here is the whole
      # failure this arm exists to prevent, arriving as an innocuous seam. The
      # {Provider::Journaled} wrap that records the question is built HERE, around
      # the bare local provider one line away, and takes no keyword of its own --
      # a decorator cannot move an endpoint it is handed, so the loopback
      # guarantee above is untouched.
      #
      # `http_middleware:` admits the egress guard and nothing else, so it cannot
      # move the endpoint either. `options:` is not a seam of that kind: a
      # Hash of sampler values rides the request BODY, and
      # nothing in it can name a host, a provider or a model. It exists because
      # a chat running this judge's own model on the same loopback server
      # shares one runner with it, and a judgement sent without the chat's
      # runner knobs reloads that runner twice. The caller resolves it -- empty
      # in the default configuration, where the chat's model is a different one.
      #
      # @param model [String] which local model answers
      # @param journal [#<<] where the {Telemetry::OracleAnswer} and the round
      #   trip's own {Telemetry::RequestSent} land
      # @param options [Hash{String=>Integer}] sampler options for the judge's
      #   request, String-keyed and already scoped to this model on this endpoint
      # @param http_middleware [Array<Array>] {Provider::HTTP::EgressGuard} entries and nothing else
      # @option options [Integer] num_batch the chat runner's prompt batch size
      # @option options [Integer] num_ctx the chat runner's context length
      # @return [Oracle::Recorded::Journaling]
      # @raise [NotAGateway] for a model name {CLOUD_MODEL} matches
      # @raise [ArgumentError] for a middleware entry that is not the egress guard
      def self.tier(model: Provider::Ollama::DEFAULT_MODEL, journal: Channel::Null::INSTANCE, options: {},
                    http_middleware: [])
        raise NotAGateway, format(LOCAL_CLOUD_MODEL, model:) if cloud_model?(model)

        oracle = definition(tier: :model)
        provider = Provider::Journaled.new(provider: Provider::Ollama.new(http_middleware: guards(http_middleware)),
                                           journal:, requester: :secret_oracle)
        Recorded::Journaling.new(definition: oracle, journal:,
                                 inner: Model.new(definition: oracle, provider:, model:, extra: options))
      end

      # The hosted tier. A cloud tag is asked at the gateway's `/api/chat`, any
      # other model at its `/v1/messages`, and the gateway's identity names which
      # of the two its upstream serves. Asked non-streaming, because the gateway
      # relays only a whole JSON answer.
      #
      # @param model [String] e.g. "glm-5.3:cloud" or "claude-haiku-5-5"
      # @param gateway [GatewayLink] proven again before every question
      # @param journal [#<<] where answers and round trips land; never the token
      # @param http_middleware [Array<Array>] {Provider::HTTP::EgressGuard} entries and nothing else
      # @return [Oracle::Recorded::Journaling]
      # @raise [ArgumentError] for a middleware entry that is not the egress guard
      def self.cloud_tier(model:, gateway:, journal: Channel::Null::INSTANCE, http_middleware: [])
        oracle = definition(tier: :cloud)
        provider = gateway_provider(gateway, model, journal, guards(http_middleware))
        Recorded::Journaling.new(definition: oracle, journal:,
                                 inner: Model.new(definition: oracle, provider:, model:, stream: false))
      end

      def self.guards(entries)
        raise ArgumentError, GUARDS_ONLY unless entries.all? { |entry| entry.first == Provider::HTTP::EgressGuard }

        entries
      end

      # The one method allowed a hosted provider here (the provider construction
      # discipline spec pins it), and it hands that provider back only behind
      # the gateway's proof.
      def self.gateway_provider(link, model, journal, http_middleware)
        bare = if cloud_model?(model)
                 Provider::Ollama.new(api_base: link.base, journal:, http_middleware:)
               else
                 Provider::Anthropic.new(api_key: GATEWAY_KEY, api_base: link.base, journal:, http_middleware:)
               end
        Proven.new(gateway: link, path: gateway_path(model),
                   provider: Provider::Journaled.new(provider: bare, journal:, requester: :secret_oracle))
      end
      private_class_method :guards, :gateway_provider

      # The gateway's address and the token that proves it, held so that only
      # the address is ever shown: the token stays out of every message,
      # inspect, journal and request.
      class GatewayLink
        LOOPBACK = "127.0.0.1"
        PROOF_SECONDS = 5
        NOT_LOOPBACK = "#{ONLY_THROUGH}; %<where>s is not one".freeze
        TOKEN_ON_ARGV = "#{ONLY_THROUGH}; give --gateway as http://127.0.0.1:<port> and nothing more (no " \
                        "?token=, user@ or #fragment): a command line is readable by every process, and the " \
                        "chat reads the token from the token file %<path>s".freeze
        UNPROVEN = "#{ONLY_THROUGH}; the listener at %<base>s did not prove it is one holding the token in " \
                   "%<path>s (%<reason>s)".freeze
        CHANGED = "#{ONLY_THROUGH}; the gateway on port %<port>d changed since the chat started (%<reason>s); " \
                  "restart the chat or the gateway".freeze
        UNSERVED = "the lain gateway at %<base>s serves %<paths>s, not %<path>s, which the secret oracle's model " \
                   "is asked at; start one with the upstream that serves it"
        UNREACHABLE = [SystemCallError, IOError, SocketError, Timeout::Error, Net::ProtocolError].freeze

        # The one place the token is read: the file the gateway on that port left.
        #
        # @param url [String] http://127.0.0.1:<port>
        # @param paths [Paths] supplies the state home the token file is under
        # @return [GatewayLink]
        # @raise [NotAGateway] for a URL that is not http on 127.0.0.1 or carries more than the
        #   address, and for a missing or unusable token file, naming its path
        def self.from_url(url, paths: Paths.new)
          uri = parsed(url)
          raise NotAGateway, format(NOT_LOOPBACK, where: where(uri)) unless loopback?(uri)

          file = Gateway::TokenFile.for(uri.port, paths:)
          raise NotAGateway, format(TOKEN_ON_ARGV, path: file.path) unless bare?(uri)

          new(port: uri.port, file:)
        end

        def self.bare?(uri) = [uri.query, uri.fragment, uri.userinfo].all?(&:nil?)

        def self.parsed(url)
          URI.parse(url.to_s)
        rescue URI::InvalidURIError
          nil
        end

        def self.loopback?(uri) = uri.is_a?(URI::HTTP) && uri.scheme == "http" && uri.host == LOOPBACK

        def self.where(uri) = uri&.host ? "#{uri.scheme}://#{uri.host}" : "the --gateway value"
        private_class_method :parsed, :loopback?, :where, :bare?

        # @param port [Integer] where the gateway listens on {LOOPBACK}
        # @param file [Gateway::TokenFile] where that gateway left its token, read now
        # @raise [NotAGateway] for a missing or unusable token file, naming its path
        def initialize(port:, file:)
          @port = port
          @file = file
          @token = token_in(file)
        end

        # @return [String] scheme, host and port: where a provider sends, with no token
        def base = "http://#{LOOPBACK}:#{@port}"

        # One exchange: a fresh nonce out, its HMAC under the token back, and
        # the paths the gateway's upstream serves.
        #
        # @param path [String] the path the question will be asked at
        # @return [void]
        # @raise [NotAGateway] unless the listener answers the nonce's HMAC and serves the path
        def prove!(path)
          nonce = SecureRandom.hex(32)
          answer = answered(identity(nonce))
          unless proof?(answer, nonce)
            raise NotAGateway, format(UNPROVEN, base:, path: @file.path, reason: answer.fetch(:reason))
          end

          paths = Array(answer.dig(:body, "paths"))
          raise NotAGateway, format(UNSERVED, base:, paths: paths.join(" and "), path:) unless paths.include?(path)
        end

        # Before a question: a gateway restarted on the same port left a new
        # token, so a failed proof reads the file once more and, if it holds
        # another token, proves again. The same token proves nothing new.
        #
        # @param path [String] the path the question will be asked at
        # @return [void]
        # @raise [NotAGateway] the first refusal when the file is unchanged; otherwise one naming
        #   the port as changed, when the file is gone or its token fails too
        def prove_again!(path)
          prove!(path)
        rescue NotAGateway => e
          renewed = changed_token
          raise e if renewed == @token

          @token = renewed
          changed { prove!(path) }
        end

        def inspect = "#<#{self.class} #{base}>"
        alias to_s inspect

        private

        def changed_token = changed { token_in(@file) }

        def changed
          yield
        rescue NotAGateway => e
          raise NotAGateway, format(CHANGED, port: @port, reason: e.message.delete_prefix("#{ONLY_THROUGH}; "))
        end

        def token_in(file)
          file.read
        rescue Gateway::TokenFile::Unusable => e
          raise NotAGateway, e.message
        end

        # The nil proxy keeps an `http_proxy` from seeing the exchange.
        def identity(nonce)
          http = Net::HTTP.new(LOOPBACK, @port, nil)
          http.open_timeout = http.read_timeout = PROOF_SECONDS
          http.get("#{Gateway::IDENTITY_PATH}?#{URI.encode_www_form(nonce:)}")
        rescue *UNREACHABLE => e
          raise NotAGateway, format(UNPROVEN, base:, path: @file.path, reason: e.class.name)
        end

        def answered(response)
          return { reason: "it answered #{response.code}" } unless response.code == "200"

          body = JSON.parse(response.body.to_s)
          body.is_a?(Hash) ? { body:, reason: "its proof did not match" } : { reason: "it answered no proof" }
        rescue JSON::ParserError
          { reason: "it answered no proof" }
        end

        def proof?(answer, nonce)
          given = answer.dig(:body, "proof").to_s
          expected = OpenSSL::HMAC.hexdigest("SHA256", @token, nonce)
          given.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(given, expected)
        end
      end

      # The provider the cloud tier asks, sending nothing until its gateway
      # proves itself again for this question. Outside {Provider::Journaled}, so
      # a refused proof journals no request that was never sent. It forwards
      # only what {Model} asks of a provider.
      class Proven
        # @return [Provider]
        attr_reader :inner

        # @param gateway [GatewayLink]
        # @param path [String] the gateway path the provider asks at
        # @param provider [Provider]
        def initialize(gateway:, path:, provider:)
          @gateway = gateway
          @path = path
          @inner = provider
        end

        # @param request [Lain::Request]
        # @return [Lain::Response]
        # @raise [NotAGateway] before any request, when the gateway does not prove itself
        def complete(request, **)
          @gateway.prove_again!(@path)
          @inner.complete(request, **)
        end

        delegate :supports?, to: :@inner
      end
    end
  end
end
