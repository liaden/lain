# frozen_string_literal: true

require "faraday"

module Lain
  class Provider
    module HTTP
      # Refuses a model request whose body carries a value the run knows to be
      # secret, before any byte of it leaves. Installed on every provider, local
      # ones too, because a loopback endpoint can forward to a hosted model.
      #
      # It refuses only on the narrow set {Sensitivity::Secrets::Egress} names;
      # every other value the masker knows, and every shape the region detector
      # finds, is journaled as a flag and the request is sent.
      #
      # It matches a value's plain spelling only: an encoded, escaped, split or
      # case-changed value passes. It is a tripwire for the value pasted or read
      # back whole, not a boundary.
      #
      # It sits in the configured-middleware seat, like {PriceTierGuard}: inside
      # retry, so every attempt is checked, and before `request :json`, so the
      # body is still the caller's Hash. The user's own configured entries run
      # before it, so it checks the body they hand on. That seat passes an
      # entry's trailing Hash positionally, so this takes Faraday's options Hash.
      #
      # The values are read per request, because one can become known mid-chat.
      # Only the body is scanned: the API key is a known value and rides the
      # headers of every request.
      class EgressGuard < Faraday::Middleware
        class Refused < Lain::Error; end

        # Raised by a literal source asked before it was bound, which this
        # guard turns into a refusal rather than a request sent unchecked.
        class NotBound < Lain::Error; end

        NOT_READY = "egress guard not ready: the request to %<host>s was refused because the run's secret " \
                    "values were not bound yet"
        KNOWN_SECRET = "the request to %<host>s was not sent: it carries %<count>d known secret value(s)"
        # A position in the request, not a turn number: a compaction or a pin
        # changes what precedes it, though not how far back the head is.
        IN_TURN = "%<refused>s, first in message %<turn>d of %<turns>d in this request (its position here, so " \
                  "after a compaction it is not the turn number). Every later request is refused the same way " \
                  "until /rewind %<back>d moves the chat to before that message"
        OUTSIDE_TURNS = "%<refused>s in %<part>s, which every request repeats. Remove the value from memory or the " \
                        "instructions file, or unset the variable that holds it, then restart the chat"
        FLAGGED = "the request to %<host>s holds %<regions>d region(s) shaped like a credential and " \
                  "%<values>d value(s) the masker knows but does not refuse on"

        # Sends whatever only the region detector flagged; the default hold.
        module Unsupervised
          # @param _summary [String]
          # @return [Boolean] true
          def self.call(_summary) = true
        end

        # @param literals [#egress] answers a {Sensitivity::Secrets::Egress}; read per request
        # @param journal [#<<] takes each {Telemetry::EgressRefused} and its Flagged sibling
        # @param hold [#call] a flagged request's summary -> true to send it
        # @return [Array] frozen, the entry the configured-middleware seat takes
        def self.entry(literals:, journal:, hold: Unsupervised) = [self, { literals:, journal:, hold: }.freeze].freeze

        # @param app [#call] the rest of the stack
        # @param options [Hash] the guard's collaborators, as {.entry} builds them
        # @option options [#egress] :literals answers a {Sensitivity::Secrets::Egress}; read per request
        # @option options [#<<] :journal takes each refusal and flag record
        # @option options [#call] :hold a flagged request's summary -> true to send it
        def initialize(app, options = {})
          super
          @literals = options.fetch(:literals)
          @journal = options.fetch(:journal)
          @hold = options.fetch(:hold, Unsupervised)
          @refused = Pattern.new
          @flagged = Pattern.new
          @sent = Sent.new
        end

        def call(env)
          inspect_body(env.url.host.to_s, env.body) unless env.body.nil?
          @app.call(env)
        end

        private

        def inspect_body(host, body)
          egress = known
          raise Refused, format(NOT_READY, host:) if egress.nil?

          scan = Scan.of(body)
          refused = @refused.over(floored(egress.refused))
          refuse(host, scan, refused) if scan.matches?(refused)
          unsent = @sent.unsent(scan.texts)
          flag(host, unsent.values.join("\0"), @flagged.over(floored(egress.flagged)))
          @sent.remember(unsent.keys)
        end

        def known
          @literals.egress
        rescue NotBound
          nil
        end

        def floored(values) = values.select { _1.bytesize >= Sensitivity::Literals::FLOOR }

        def refuse(host, scan, pattern)
          found = scan.carried(pattern.values)
          turn = scan.first_turn(pattern)
          @journal << Telemetry::EgressRefused.new(host:, count: found.size, turn:)
          raise Refused, refusal(format(KNOWN_SECRET, host:, count: found.size), scan, turn, pattern)
        end

        def refusal(refused, scan, turn, pattern)
          return format(OUTSIDE_TURNS, refused:, part: scan.part(pattern)) if turn.nil?

          format(IN_TURN, refused:, turn:, turns: scan.turns, back: scan.turns - turn + 1)
        end

        # Over what this provider has not sent before only, so a flagged value
        # is told once rather than on every request that resends it.
        def flag(host, fresh, pattern)
          regions = Sensitivity::Regions.detect(fresh).size
          values = pattern.match?(fresh) ? pattern.values.count { fresh.include?(_1) } : 0
          return if (regions + values).zero?

          @journal << Telemetry::EgressRefused::Flagged.new(host:, regions:, values:)
          summary = format(FLAGGED, host:, regions:, values:)
          raise Refused, "#{summary}, and it was not approved" unless @hold.call(summary)
        end

        # How a set of values is looked for in a text. One `include?` per value
        # reads the text once each, at about 0.18 ms a MB; one alternation reads
        # it once whatever the count, but at 0.4 to 3.7 ms a MB, slowest when the
        # values begin with characters the text is full of. So few values are
        # looked for one by one, and many through the alternation.
        class Pattern
          ONE_BY_ONE = 16

          Compiled = Data.define(:values, :regexp) do
            # @param text [String] binary
            # @return [Boolean]
            def match?(text)
              values.size <= ONE_BY_ONE ? values.any? { text.include?(_1) } : regexp.match?(text)
            end
          end

          def initialize
            @compiled = Compiled.new(values: [].freeze, regexp: Regexp.union)
          end

          # Recompiled only when the values change.
          #
          # @param values [Array<String>]
          # @return [Compiled]
          def over(values)
            compiled = @compiled
            compiled = @compiled = Compiled.new(values: values.freeze, regexp: Regexp.union(values)) \
              unless compiled.values == values
            compiled
          end
        end
        private_constant :Pattern

        # The digests of the texts already sent through this provider, so the
        # region detector reads only what a request adds: every request resends
        # the history, and detection costs about 90 ms a MB. Least recently sent
        # goes first past {BOUND} texts, a message or the system prompt and
        # tools each; a chat longer than that detects its oldest again.
        class Sent
          BOUND = 16_384

          def initialize
            @digests = {}
            @lock = Mutex.new
          end

          # @param texts [Array<String>]
          # @return [Hash{String=>String}] digest to text, for those not yet sent
          def unsent(texts)
            keyed = texts.to_h { [Ext.blake3_hex(_1), _1] }
            @lock.synchronize { keyed.reject { |digest, _| @digests.key?(digest) && touch(digest) } }
          end

          # Only once the request passed, so a declined one is detected again.
          #
          # @param digests [Array<String>]
          def remember(digests)
            @lock.synchronize do
              digests.each { @digests[_1] = true }
              @digests.shift while @digests.size > BOUND
            end
          end

          private

          def touch(digest)
            @digests[digest] = @digests.delete(digest)
          end
        end
        private_constant :Sent

        # A body's strings as bytes, each message's and each other part's
        # apart, so the first turn carrying a value is found by scanning the
        # messages in order, and a value outside them is named by its part.
        PARTS = { "the system prompt" => %i[system], "the tool schemas" => %i[tools] }.freeze
        private_constant :PARTS

        Scan = Data.define(:messages, :parts) do
          def self.of(body)
            hash = body.is_a?(Hash) ? body.transform_keys(&:to_sym) : { body: }
            named = PARTS.transform_values { |keys| joined(hash.slice(*keys)) }
            rest = joined(hash.except(:messages, *PARTS.values.flatten))
            new(messages: Array(hash[:messages]).map { joined(_1) }, parts: named.merge("the request settings" => rest))
          end

          # Joined, then relabelled as bytes in place: copying each string to
          # binary first doubled the cost of the pass. Strings whose encodings
          # cannot join take the copying path.
          def self.joined(value)
            found = strings(value)
            found.join("\0").force_encoding(Encoding::BINARY)
          rescue Encoding::CompatibilityError
            found.map(&:b).join("\0")
          end

          def self.strings(value)
            case value
            when Hash then value.flat_map { |key, inner| [*strings(key), *strings(inner)] }
            when Array then value.flat_map { strings(_1) }
            when String then [value]
            when Symbol then [value.name]
            else []
            end
          end

          def matches?(pattern) = texts.any? { pattern.match?(_1) }

          # @return [Array<String>] the known values the body carries
          def carried(values) = values.select { |value| texts.any? { _1.include?(value) } }

          # @return [Integer, nil] 1-based
          def first_turn(pattern) = messages.index { pattern.match?(_1) }&.succ

          # @return [String] the first part outside the messages that matches
          def part(pattern) = parts.find { |_, text| pattern.match?(text) }&.first || "the request settings"

          def turns = messages.size

          def texts = [*messages, *parts.values]
        end
        private_constant :Scan
      end
    end
  end
end
