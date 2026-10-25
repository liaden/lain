# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "zlib"

module Lain
  module Gateway
    Upstream = Data.define(:base, :auth_header, :key_env)

    # The one allow-listed host a gateway forwards to. The client's headers
    # never reach it: the body is sent with the gateway's own credential,
    # read from the gateway process's environment and nowhere else.
    #
    # @!attribute [r] base
    #   @return [String] a key of {UPSTREAMS}
    # @!attribute [r] auth_header
    #   @return [String] the header the gateway's credential travels in
    # @!attribute [r] key_env
    #   @return [String] the gateway process's variable holding that credential
    class Upstream
      # The upstream or the path is not one the gateway may reach.
      class NotAllowed < Lain::Error; end
      # The gateway's environment holds no usable credential for its upstream.
      class MissingKey < Lain::Error; end
      # The upstream could not be reached, or did not answer whole in time.
      class ForwardFailed < Lain::Error; end

      HOSTS = "the gateway forwards only to #{UPSTREAMS.keys.join(" and ")}, spelled exactly so".freeze
      PLAINTEXT = "the gateway forwards only over https, never plaintext"
      PATHS = "the gateway forwards to %<base>s only at %<paths>s, not %<path>p"
      FAILED = "the gateway's forward to %<host>s failed: %<reason>s"
      OPEN_TIMEOUT = 10
      # A non-streaming answer arrives whole, so a slow model holds the whole wait.
      DEADLINE = 600
      MAX_RESPONSE_BYTES = 16 * 1024 * 1024
      UNREACHABLE = [SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError, Timeout::Error,
                     Net::ProtocolError, Net::HTTPBadResponse, Zlib::Error].freeze

      # @param url [String] the upstream the human named
      # @return [Upstream]
      # @raise [NotAllowed] for anything but a base {UPSTREAMS} holds, spelled exactly
      def self.for(url)
        base, route = UPSTREAMS.assoc(url.to_s.delete_suffix("/"))
        raise NotAllowed, url.to_s.match?(/\Ahttp:/i) ? PLAINTEXT : HOSTS unless route

        new(base:, auth_header: route.fetch(:auth_header), key_env: route.fetch(:key_env))
      end

      # @raise [NotAllowed] unless the three fields are one row of {UPSTREAMS},
      #   so `new` and `with` cannot reach past the allow-list
      def initialize(base:, auth_header:, key_env:)
        row = UPSTREAMS.fetch(base) { raise NotAllowed, HOSTS }
        raise NotAllowed, HOSTS unless row.values_at(:auth_header, :key_env) == [auth_header, key_env]

        super
      end

      # @param path [String] the request path, one the upstream's row lists
      # @param body [String] the inspected body, sent byte for byte
      # @return [Net::HTTPResponse] its body read whole, with the gateway's key masked
      # @raise [NotAllowed] for a path the row does not list
      # @raise [MissingKey] when the environment lacks a usable {#key_env}
      # @raise [ForwardFailed] naming the host, never the key, when the upstream
      #   cannot be reached, overruns {DEADLINE} or answers over {MAX_RESPONSE_BYTES}
      def forward(path, body)
        paths = route.fetch(:paths)
        raise NotAllowed, format(PATHS, base:, paths: paths.join(", "), path:) unless paths.include?(path)

        exchange(request(path, body, key), key)
      end

      private

      def route = UPSTREAMS.fetch(base)

      def host = URI.parse(base).host

      # A CR or LF in the key would raise from Net::HTTP with the value in the message.
      def key
        value = ENV.fetch(key_env, "")
        return value unless value.empty? || value.match?(/[[:cntrl:]]/)

        raise MissingKey, "the gateway's environment has no usable #{key_env}"
      end

      def request(path, body, key)
        Net::HTTP::Post.new(path).tap do |post|
          post["Content-Type"] = "application/json"
          post[auth_header] = format(route.fetch(:credential), key)
          route.fetch(:headers).each { |name, value| post[name] = value }
          post.body = body
        end
      end

      # The nil proxy keeps an `http_proxy` in the environment from receiving the credential.
      def exchange(post, key)
        Timeout.timeout(DEADLINE, nil, "no whole answer within #{DEADLINE}s") do
          Net::HTTP.start(host, 443, nil, use_ssl: true, open_timeout: OPEN_TIMEOUT) do |http|
            response, buffer = read(http, post)
            response.tap { whole(_1, masked(buffer, key)) }
          end
        end
      rescue *UNREACHABLE => e
        raise ForwardFailed, format(FAILED, host:, reason: masked(e.message, key))
      end

      def read(http, post)
        buffer = +""
        response = http.request(post) { |answer| answer.read_body { |chunk| append(buffer, chunk) } }
        [response, buffer]
      end

      def append(buffer, chunk)
        buffer << chunk
        raise ForwardFailed, format(FAILED, host:, reason: "an answer over #{MAX_RESPONSE_BYTES} bytes") if
          buffer.bytesize > MAX_RESPONSE_BYTES
      end

      # A mask changes the body's length, so a Content-Length the upstream sent no longer holds.
      def whole(response, body)
        response.body = body
        response["content-length"] &&= body.bytesize.to_s
      end

      def masked(text, key) = text.b.gsub(key.b, format(Sensitivity::Regions::PLACEHOLDER, 1))
    end
  end
end
