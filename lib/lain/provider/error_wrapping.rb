# frozen_string_literal: true

require "active_support"
require "active_support/concern"
require "faraday"
require "net/http"
require "socket"

module Lain
  class Provider
    # The `APIError` / `APIStatusError` family every backend over the vendored
    # {Provider::HTTP} transport raises, declared once.
    #
    # All four includers need the SAME two classes and the SAME rule: a
    # vendored transport error carrying a status becomes an `APIStatusError`
    # with that status lifted out (so callers branch on it without unwrapping
    # `#cause`), anything else becomes a plain `APIError`. The original is
    # always preserved as `#cause`.
    #
    # == Why the constants stay nested, and why this is a factory
    #
    # The pair CANNOT be hoisted here and inherited. `rescue
    # Provider::Ollama::APIStatusError` means "the local chat backend failed",
    # not "some HTTP backend failed" -- one shared pair would make every
    # `rescue` catch all four at once, and a bench arm's error attribution would
    # stop meaning anything.
    #
    # The base differs too: the three Providers root at {Lain::Error}, while
    # {Embedder::Ollama} must root at {Embedder::Error} so `rescue
    # Embedder::Error` still catches every embedding failure. `included` runs at
    # include time, before the includer's body has declared anything this could
    # read, so the base arrives as an argument: `.under(base)` returns the
    # concern to include. One self-describing line at the top of each class.
    #
    # == One marker across the family, for READING, never for rescuing
    #
    # The SDK oracles declare identically-named pairs of their own in
    # spec/support, because they wrap the official SDK's errors rather than
    # vendored-transport ones. So `rescue Anthropic::APIError` still does not
    # catch an `AnthropicReference` failure. {RoundTripFailure} marks every
    # family's APIError so a reader classifying a stopped ask by type
    # ({Agent::StopReason}) need not enumerate the families; a `rescue` of it
    # would catch every backend at once, which is the thing the nesting above
    # exists to prevent.
    module ErrorWrapping
      # Every includer's APIError, whatever its base.
      module RoundTripFailure; end

      # Whether any attempt of ONE round trip can have written a request byte.
      #
      # faraday-retry hands the round trip back only its LAST failure, so a
      # refused connection on the final attempt proves nothing about an earlier
      # attempt that reached a server. The retry taps tell a witness each
      # abandoned attempt's failure off the retried env, and
      # {Wrapping#wrapping_errors} asks it about the last one.
      #
      # Only a connection that never opened provably sent nothing: refused,
      # unroutable, unresolvable, or not opened in time. A reset, a broken pipe
      # and a read timeout can each follow a written byte, and a
      # ConnectionFailed built from a bare string names no cause at all.
      #
      # The proof is by errno CLASS, not by the phase that raised it. On Linux an
      # established socket can surface a soft ICMP error (EHOSTUNREACH,
      # ENETUNREACH) once its retransmits time out, after bytes were written;
      # the transport's read and write timeouts fire long before that, which is
      # what keeps it unreachable. Lengthen those past `tcp_retries2` and this
      # list stops being a proof.
      #
      # Mutable, and one per round trip: the attempts of one round trip run in
      # sequence on one fiber.
      class WireWitness
        UNCONNECTED = [Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
                       SocketError, Net::OpenTimeout].freeze

        # A round trip nobody witnessed cannot be proved unsent.
        module Unwitnessed
          def self.attempted(_exception) = self

          def self.pre_wire?(_exception) = false
        end

        def initialize
          @reached = false
        end

        # @param exception [Exception] an abandoned attempt's failure
        # @return [self]
        def attempted(exception)
          @reached ||= !unconnected?(exception)
          self
        end

        # @param exception [Exception] the round trip's last failure
        def pre_wire?(exception) = !@reached && unconnected?(exception)

        private

        def unconnected?(exception)
          exception.is_a?(Faraday::ConnectionFailed) &&
            UNCONNECTED.any? { |failure| exception.wrapped_exception.is_a?(failure) }
        end
      end

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
        #   rescues one, so uncontained it escapes the entire stack: on
        #   Anthropic that is `--provider anthropic` printing a backtrace when a
        #   VPN drops, on Ollama it is "ollama is not running" -- the ordinary
        #   case for the default summarizer arm -- taking out the turn from the
        #   render path.
        #
        # Written here rather than per backend because two of the four copies
        # had gone MISSING, and they went missing precisely because an absent
        # copy is invisible while a wrong one is not. What legitimately differs
        # per backend is the round trip inside the block, not the arms around
        # it.
        #
        # A connection-level failure the round trip's witness proves unsent
        # becomes the family's `PreWireError` -- still an APIError, so every
        # rescue of the family catches it.
        def wrapping_errors(witness = WireWitness::Unwitnessed)
          yield
        rescue Provider::HTTP::Error => e
          raise wrap_error(e)
        rescue Faraday::Error => e
          raise witness.pre_wire?(e) ? pre_wire_error_class : api_error_class, e.message
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
      #   `APIStatusError`, `PreWireError`, and private `#wrapping_errors` / `#wrap_error` on
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
      # `Lain::Provider::Anthropic::APIError.name` and every backtrace read
      # exactly as they did when the classes were hand-written.
      def self.declare_family(includer, base)
        api_error = includer.const_set(:APIError, Class.new(base) { include RoundTripFailure })
        status_error = includer.const_set(:APIStatusError, Class.new(api_error) { include Status })
        pre_wire_error = includer.const_set(:PreWireError, Class.new(api_error) { include Lain::PreWire })
        includer.class_eval do
          define_method(:api_error_class) { api_error }
          define_method(:api_status_error_class) { status_error }
          define_method(:pre_wire_error_class) { pre_wire_error }
          private :api_error_class, :api_status_error_class, :pre_wire_error_class
        end
      end
    end
  end
end
