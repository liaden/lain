# frozen_string_literal: true

require "net/http"
require "vcr"

# The one true way through the offline default, for :api_integration and :live.
#
# `WebMock.allow_net_connect!` is NOT sufficient once VCR has hooked into
# WebMock (see vcr_configuration.rb): from that point VCR -- not WebMock --
# decides whether an unstubbed request goes out, and its
# `allow_http_connections_when_no_cassette` is false. So flipping only the
# WebMock switch leaves the door shut, and a spec that "opts into the network"
# raises `VCR::Errors::UnhandledHTTPRequestError` instead of reaching the API.
# Both switches have to move together, and they have to move back together.
#
# Extracted into a named collaborator for one reason: it makes the capability
# PROVABLE in the default suite. The untagged guards live in
# spec/network_posture_spec.rb (a real spec file, so parallel workers run them
# once, not once per worker): if someone re-breaks the path -- e.g. drops the
# `VCR.turned_off` and trusts `allow_net_connect!` alone -- the default
# `rspec` run goes red. A regression spec tagged :api_integration would be
# excluded by default and catch nothing, which is exactly how this bug
# slipped in the first time.
#
# `.permit` is the blunt opt-in and stays that way. `.permit_loopback` below is
# the narrow one -- one port, VCR left on -- and is what a spec wanting a local
# fake upstream or a local recording should reach for.
module NetworkAccess
  # Every name this machine answers to on its own loopback interface. A caller
  # names a PORT and nothing else, so a permission that could reach another host
  # is not merely untested here -- it cannot be written.
  #
  # Matching is on the SPELLING, which is exact for the two literals and taken on
  # the resolver's word for `localhost`. RFC 6761 reserves that name for loopback
  # and every resolver here honours it, so the residual is a machine whose own
  # resolver already lies -- and dropping the name would break T3's default
  # `OLLAMA_API_BASE`. Recorded rather than defended against. Nothing wider gets
  # in: `localhost.evil.example.com` and `user:pw@evil.example.com` are both
  # ordinary non-matches, which the posture spec's sibling probe checked.
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  PORTS = (1..65_535)

  # Counted, not a flag: nested or overlapping permissions for the same port
  # must each survive the other's release. Process-wide rather than
  # thread-local, because the thread that issues a request need not be the one
  # that took the permission -- a harness whose server runs in one thread and
  # whose client runs in another needs exactly that. The cost is that concurrent
  # permissions UNION: while two examples in one process each hold a port, either
  # thread can reach either port. Within a process that runs its examples
  # sequentially this is not reachable; a spec that permits a port and then fans
  # out across threads should know it.
  @held = Hash.new(0)
  @lock = Mutex.new

  # Run the block with real network access, then restore isolation no matter
  # what the block does.
  def self.permit(&block)
    WebMock.allow_net_connect!
    VCR.turned_off(ignore_cassettes: true, &block)
  ensure
    WebMock.disable_net_connect!
  end

  # Permit exactly one loopback port for the duration of the block, leaving the
  # offline posture intact for every other destination and leaving VCR ON.
  #
  # Unlike `.permit` above, this moves NEITHER switch: VCR stays on and
  # `WebMock.allow_net_connect!` is never called. It does not have to. Once
  # `hook_into :webmock` has run, VCR aliases `WebMock.net_connect_allowed?` to
  # `true` for as long as it is turned on (vcr/library_hooks/webmock.rb:160-171),
  # so WebMock's own switch decides nothing and VCR's request handler is the
  # whole gate. Narrowing therefore means teaching THAT gate about one port,
  # which is the `ignore_request` hook registered at the bottom of this file.
  #
  # The permission is takeable AFTER a server has bound -- a harness that binds
  # port 0 learns its port from the kernel and cannot name it any earlier.
  #
  # One rule decides what a permitted request meets, and it is what lets a fake
  # upstream and a real recording share one method: **an inserted cassette
  # wins.** With no cassette the request bypasses VCR and reaches the socket.
  # With a cassette inserted VCR handles it exactly as it always would, replaying
  # or recording -- which matters because VCR refuses to record a request it
  # ignored (vcr.rb:390-395), so a permission that bypassed unconditionally would
  # write an empty cassette and look like it worked.
  #
  # Read that rule the other way before debugging: a cassette that is REPLAYING
  # does not merely take precedence, it makes this method inert, and VCR's
  # refusal names neither the port nor the cassette. An example carrying the
  # `:vcr` tag has a cassette for its whole body (`configure_rspec_metadata!`),
  # so a seam spec that acquires that tag loses its socket and gets a generic
  # "VCR does not know how to handle this request". `spec/network_posture_spec.rb`
  # pins that shape deliberately -- it is where the cause is written down.
  def self.permit_loopback(port)
    raise ArgumentError, "permit_loopback needs a block: the permission lasts as long as one" unless block_given?

    hold(port)
    begin
      yield
    ensure
      release(port)
    end
  end

  # The narrow allowance itself, asked once per request by the hook below.
  def self.bypass?(request)
    VCR.current_cassette.nil? && permitted?(request.parsed_uri)
  end

  def self.permitted?(uri)
    # URI#host keeps the brackets an IPv6 literal is written with; the host list
    # spells the address without them.
    LOOPBACK_HOSTS.include?(uri.host.to_s.downcase.delete("[]")) && held.include?(uri.port)
  end
  private_class_method :permitted?

  def self.hold(port)
    raise ArgumentError, "a loopback port must be an integer in #{PORTS}, got #{port.inspect}" unless port?(port)

    @lock.synchronize { @held[port] += 1 }
  end
  private_class_method :hold

  def self.release(port)
    @lock.synchronize do
      @held[port] -= 1
      @held.delete(port) unless @held[port].positive?
    end
  end
  private_class_method :release

  def self.held
    @lock.synchronize { @held.keys }
  end
  private_class_method :held

  def self.port?(port)
    port.is_a?(Integer) && PORTS.cover?(port)
  end
  private_class_method :port?
end

# Registered once, at load, and inert until a block takes a permission: a VCR
# ignore hook cannot be un-registered individually, so the allowance has to be
# data the hook reads rather than a hook installed and removed around a block.
# The host check runs before the lock, so the cost for the suite's every other
# request is one three-element `include?`.
VCR.configure do |config|
  config.ignore_request { |request| NetworkAccess.bypass?(request) }
end
