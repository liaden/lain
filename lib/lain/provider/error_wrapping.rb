# frozen_string_literal: true

require "active_support"
require "active_support/concern"
require "faraday"

module Lain
  class Provider
    # The `APIError` / `APIStatusError` family every backend over the vendored
    # {Provider::HTTP} transport raises, declared once.
    #
    # Four classes need it -- {Provider::Anthropic}, {Provider::Bedrock},
    # {Provider::Ollama}, {Embedder::Ollama} -- and all four need the SAME two
    # classes and the SAME wrapping rule: a vendored transport error carrying a
    # status becomes an `APIStatusError` with that status lifted out (so callers
    # branch on it without unwrapping `#cause`), anything else becomes a plain
    # `APIError`. The original is always preserved as `#cause`.
    #
    # == Why the constants stay nested, and why this is a factory
    #
    # The pair CANNOT be hoisted here and inherited. `rescue
    # Provider::Ollama::APIStatusError` means "the local chat backend failed",
    # not "some HTTP backend failed" -- one shared pair would make every
    # `rescue` catch all four at once, and a bench arm's error attribution would
    # stop meaning anything. So the `included` block const_sets the pair into
    # the includer, where each class keeps its own nested identity.
    #
    # The base differs too: the three Providers root at {Lain::Error}, while
    # {Embedder::Ollama} must root at {Embedder::Error} so `rescue
    # Embedder::Error` still catches every embedding failure. `included` runs at
    # include time, before the includer's body has declared anything this could
    # read, so the base arrives as an argument: `.under(base)` returns the
    # concern to include. One self-describing line at the top of each class.
    #
    # == Not a marker across the family
    #
    # Two identically-named pairs stay OUTSIDE this module on purpose: the SDK
    # oracles {Provider::AnthropicReference} and {Provider::BedrockReference}
    # declare their own in spec/support, because they wrap the official SDK's
    # errors rather than vendored-transport ones. So `rescue
    # Anthropic::APIError` still does not catch an `AnthropicReference`
    # failure -- see that class's own note. Nothing here introduces the shared
    # marker module that would change that.
    module ErrorWrapping
      # What makes an `APIStatusError` more than a name: the HTTP status, lifted
      # out of the wrapped error so a caller branches on it without unwrapping
      # `#cause`. A module rather than a class body inside {.under}, so each
      # per-includer subclass mixes in one definition of this.
      module Status
        attr_reader :status

        def initialize(message = nil, status: nil)
          super(message)
          @status = status
        end
      end

      # The wrapping rule itself, identical for all four includers.
      module Wrapping
        private

        # BOTH error arms of one round trip, in one place. They are two because
        # the vendored stack raises from two different heights:
        #
        # - A non-2xx passes through {Provider::HTTP::ErrorMiddleware}, the
        #   INNERMOST handler, and arrives as a {Provider::HTTP::Error} -- a
        #   plain StandardError, deliberately not a Faraday class, which is why
        #   the two arms cannot shadow each other in either order.
        # - A CONNECTION-level failure (ConnectionFailed, SSLError, an adapter
        #   timeout, a torn body's ParsingError) never reaches that middleware
        #   at all, so exhausted retries re-raise the last transport failure as
        #   a bare Faraday class. Nothing above a Provider or an Embedder
        #   rescues one, so uncontained it escapes the entire stack: on Bedrock
        #   that is `--provider bedrock` printing a backtrace when a VPN drops,
        #   on Ollama it is "ollama is not running" -- the ordinary case for the
        #   default summarizer arm -- taking out the turn from the render path.
        #
        # This block lives here rather than written out per backend because two
        # of the four copies had gone MISSING, and they went missing precisely
        # because an absent copy is invisible while a wrong one is not. What
        # legitimately differs per backend is the round trip inside the block,
        # not the arms around it. A backend that genuinely needs a third arm
        # rescues it inside its own block (see {Provider::Ollama#stream_body},
        # whose JSON::ParserError arm sits below this one and passes through).
        def wrapping_errors
          yield
        rescue Provider::HTTP::Error => e
          raise wrap_error(e)
        rescue Faraday::Error => e
          raise api_error_class, e.message
        end

        # ONE body has to raise each includer's OWN pair, so the classes arrive
        # as messages ({#api_error_class}) rather than as constants resolved off
        # `self.class`: `const_get` inherits by default, so a missing constant
        # would resolve to a top-level `::APIError` instead of failing, and
        # `inherit: false` would break the day a backend is subclassed. A
        # message answers correctly in both cases and NoMethodErrors loudly if
        # the concern was never included.
        #
        # A vendored {Provider::HTTP::Error} built from a bare String has no
        # `response` at all (its #initialize shifts the String into `message`),
        # and a response object that cannot answer #status is the same absence
        # -- both mean "no status to lift", which is the plain APIError. The
        # `status.nil?` test rather than the original `status ?` differs only for
        # `status == false`, which no HTTP response produces.
        def wrap_error(error)
          status = error.response.respond_to?(:status) ? error.response.status : nil
          return api_error_class.new(error.message) if status.nil?

          api_status_error_class.new(error.message, status:)
        end
      end

      # @param base [Class] the class the pair descends from -- {Lain::Error}
      #   for a {Provider}, {Embedder::Error} for an {Embedder}.
      # @return [Module] a concern; including it defines `APIError`,
      #   `APIStatusError`, and private `#wrapping_errors` / `#wrap_error` on
      #   the includer. The module is anonymous, so `ancestors` shows one
      #   `#<Module:0x…>` entry -- ask `include?(ErrorWrapping::Wrapping)`, which
      #   is named and spec-pinned, rather than `include?(ErrorWrapping)`.
      def self.under(base)
        Module.new do
          extend ActiveSupport::Concern
          include Wrapping

          included { ErrorWrapping.declare_family(self, base) }
        end
      end

      # The pair, plus the two readers {Wrapping} reaches them through. Named
      # and separate because it is the whole of {.under}'s work, and because
      # `const_set` is what gives each anonymous `Class.new` its real name -- so
      # `Lain::Provider::Bedrock::APIError.name` and every backtrace read
      # exactly as they did when the classes were hand-written.
      def self.declare_family(includer, base)
        api_error = includer.const_set(:APIError, Class.new(base))
        status_error = includer.const_set(:APIStatusError, Class.new(api_error) { include Status })
        includer.class_eval do
          define_method(:api_error_class) { api_error }
          define_method(:api_status_error_class) { status_error }
          private :api_error_class, :api_status_error_class
        end
      end
    end
  end
end
