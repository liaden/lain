# frozen_string_literal: true

require "socket"

module Lain
  module CLI
    # `lain remote pair NAME` and `lain remote revoke NAME`: the phones the relay
    # admits. The relay rereads the devices file on its own, so neither verb
    # restarts it, and a revoke closes the device's connection at that reread.
    class Remote
      VERBS = %w[pair revoke].freeze
      RELAY_PORT = 7820
      TAILNET_INTERFACE = "tailscale0"
      UNKNOWN_VERB = "lain remote knows #{VERBS.join(" and ")}, not %<verb>p".freeze
      NO_NAME = "lain remote %<verb>s needs a device name"
      NO_TAILNET = "none, this host has no #{TAILNET_INTERFACE} address, and the relay serves only the tailnet".freeze
      ONCE = "Enter both in the settings of the lain app on the phone. The token is not shown again."
      REVOKED = "revoked %<name>s; the relay closes its connection when it rereads the file"

      # @param verb [String] pair or revoke
      # @param name [String, nil] the device
      # @param sink [#puts] where the result goes
      # @param paths [Paths] supplies the state home the devices file lives under
      # @param tailnet [#call] returns this host's tailnet addresses as Addrinfo
      def initialize(verb:, name:, sink:, paths: Paths.new, tailnet: method(:tailnet_addresses))
        @verb = verb
        @name = name
        @sink = sink
        @devices = Lain::Remote::Devices.for(paths:)
        @tailnet = tailnet
      end

      # @return [Integer] the exit status
      # @raise [Lain::Error] for an unknown verb, a missing name, or a pair or revoke the devices file refuses
      def run
        raise Lain::Error, format(UNKNOWN_VERB, verb: @verb) unless VERBS.include?(@verb)
        raise Lain::Error, format(NO_NAME, verb: @verb) if @name.to_s.empty?

        @verb == "pair" ? pair : revoke
        0
      end

      private

      def pair
        token = @devices.pair(@name)
        @sink.puts("paired #{@name}", "token: #{token}", "relay: #{relay_address}", ONCE)
      end

      def revoke
        @devices.revoke(@name)
        @sink.puts(format(REVOKED, name: @name))
      end

      def relay_address
        addresses = @tailnet.call
        address = addresses.find(&:ipv4?) || addresses.first
        address ? Addrinfo.tcp(address.ip_address, RELAY_PORT).inspect_sockaddr : NO_TAILNET
      end

      def tailnet_addresses
        Socket.getifaddrs.select { |interface| interface.name == TAILNET_INTERFACE }.filter_map(&:addr).select(&:ip?)
      end
    end
  end
end
