# frozen_string_literal: true

require "ipaddr"
require "uri"

module Lain
  class Provider
    class Admission
      # WHICH SERVER an endpoint string names, and whether that server is on this
      # machine. Extracted from {Admission} when the class outgrew its length
      # limit, which was the right signal: a gate that counts callers and a
      # classifier that reads URLs are two jobs, and only the second one needs to
      # know what `::ffff:127.0.0.1` is.
      #
      # NOT {CLI::Backend::Endpoint}, which validates an operator's `--api-base`
      # at launch and REFUSES a bad one. This never refuses anything: it runs on
      # the round-trip path, where the only useful answers are a key and a
      # boolean.
      #
      # The two questions are deliberately answered in one place, because they
      # have to agree. {DEFAULT_WIDTH}'s justification is that every loopback
      # spelling is one server -- and if {.canonical} did not fold exactly what
      # {.local?} folds, the keying would defeat that argument by handing each
      # spelling its own slot. It did, once: F26 reproduced through the real
      # construction sites after admission had supposedly fixed it.
      module Endpoint
        # Loopback by NAME rather than by address. RFC 6761 reserves `localhost`
        # and every name under it for loopback, so `foo.localhost` is as local as
        # `localhost` -- and a developer proxy is exactly where such a name shows
        # up. Case-insensitive because a hostname is.
        LOOPBACK_NAMES = /\A(?:localhost|.+\.localhost)\z/i

        # What every local spelling folds to in a key. The token is arbitrary;
        # that there is exactly ONE of it is not.
        LOCAL_HOST = "localhost"

        module_function

        # The identity of the SERVER `endpoint` names, as a registry key.
        #
        # Folds what {.local?} folds: every loopback spelling becomes
        # {LOCAL_HOST}, and the host is downcased. A trailing slash goes, and the
        # port is made explicit (`URI#port` supplies the scheme default) so
        # `http://h` and `http://h:80` are one server.
        #
        # FOLDED THAT FAR AND NO FURTHER. A port or a base path names a different
        # service, so both are kept -- folding either would silently share one
        # slot between two servers, which is the same defect as the one this
        # method exists to fix, pointing the other way.
        #
        # An endpoint with no host keys on its own trimmed text, never
        # downcased: a unix socket path is case-SENSITIVE.
        #
        # @param endpoint [String]
        # @return [String]
        def canonical(endpoint)
          uri = parse(endpoint)
          host = uri&.hostname
          return trimmed(endpoint.to_s) if host.nil? || host.empty?

          name = local_host?(host) ? LOCAL_HOST : host.downcase
          "#{uri.scheme&.downcase}://#{name}:#{uri.port}#{trimmed(uri.path.to_s)}"
        end

        # Whether `endpoint` names a server on THIS machine, which is the only
        # kind {Admission::DEFAULT_WIDTH} makes a claim about.
        #
        # == Both misclassifications are harmful, in OPPOSITE directions
        #
        # Read this before adjusting anything here, because the two errors do not
        # look alike and only one of them is loud.
        #
        # A FALSE POSITIVE -- calling a hosted endpoint local -- gates it at one
        # in flight and SERIALISES concurrent subagents, the throughput
        # regression the locality rule exists to prevent. A FALSE NEGATIVE --
        # calling a local endpoint hosted -- hands it {Admission::Null} and
        # leaves F26 live, SILENTLY: nothing errors, two round trips simply
        # overlap on a one-slot server again. Neither direction is the safe
        # default, so neither may be relaxed to fix the other.
        #
        # == What counts as local
        #
        # Loopback in every spelling, because they are all one server: the name
        # `localhost` and RFC 6761's subdomains of it, a trailing-dot FQDN
        # (`localhost.` is the same name, explicitly rooted), any address in
        # 127.0.0.0/8 -- `127.0.0.1` and `127.5.5.5` reach one ollama -- `::1`,
        # and the IPv4-mapped forms {IPAddr#loopback?} folds in. Also the
        # UNSPECIFIED address, `0.0.0.0` and `::`: `#loopback?` answers false for
        # it, but as a destination it means this host, `Backend::Endpoint`
        # accepts it, and a bind-all base is a thing operators really write.
        #
        # A hostname is never RESOLVED to decide this. `myollama` in `/etc/hosts`
        # pointing at 127.0.0.1 reads as hosted, deliberately: a DNS lookup on
        # the round-trip path is exactly the synchronous I/O this must not do,
        # and the answer could change under a running session.
        #
        # == And what an absent host means
        #
        # A `unix:` scheme, or no scheme with an absolute (or empty) path, is a
        # socket or a filesystem path and is local by construction. A bare
        # `api.anthropic.com` is NOT: `URI` reads it as a relative PATH with no
        # host, so treating "no host" as local on its own silently gated a hosted
        # endpoint. Only the CLI is protected from that by validation at
        # `Backend#initialize`; every direct `api_base:` caller -- bench, the
        # oracle tiers, future wiring -- reaches here unfiltered.
        #
        # An UNPARSEABLE endpoint answers false rather than raising. A gate is
        # not the right place to refuse a malformed base.
        #
        # @param endpoint [String] the resolved endpoint
        # @return [Boolean]
        def local?(endpoint)
          uri = parse(endpoint)
          return false if uri.nil?

          host = uri.hostname
          return hostless_local?(uri) if host.nil? || host.empty?

          local_host?(host)
        end

        # @return [URI::Generic, nil] nil when the endpoint will not parse at all
        def parse(endpoint)
          URI(endpoint.to_s)
        rescue URI::InvalidURIError
          nil
        end
        private_class_method :parse

        # The trailing dot is a FQDN's explicit root and names the same host, so
        # it is stripped before either test rather than being its own spelling.
        # @return [Boolean]
        def local_host?(host)
          name = host.downcase.delete_suffix(".")
          LOOPBACK_NAMES.match?(name) || loopback_address?(name)
        end
        private_class_method :local_host?

        # A hostname that is not an address at all is not loopback BY ADDRESS --
        # {LOOPBACK_NAMES} has already had its say by the time this is asked.
        # `to_i.zero?` is the unspecified address in both families, which
        # {IPAddr#loopback?} does not cover.
        # @return [Boolean]
        def loopback_address?(host)
          address = IPAddr.new(host)
          address.loopback? || address.to_i.zero?
        rescue IPAddr::InvalidAddressError
          false
        end
        private_class_method :loopback_address?

        # No host, so the question is whether this names something on the
        # filesystem or a hostname `URI` parsed as a relative path. An opaque
        # form (`api.anthropic.com:443`, which parses with the HOST as its
        # scheme) falls through to false for the same reason.
        # @return [Boolean]
        def hostless_local?(uri)
          return true if uri.scheme&.downcase == "unix"
          return false unless uri.scheme.nil?

          path = uri.path.to_s
          path.empty? || path.start_with?("/")
        end
        private_class_method :hostless_local?

        # One trailing slash, so `.../11434/` and `.../11434` are one server.
        # @return [String]
        def trimmed(text) = text.delete_suffix("/")
        private_class_method :trimmed
      end
    end
  end
end
