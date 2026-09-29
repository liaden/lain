# frozen_string_literal: true

module Lain
  module CLI
    # Installs the OS signal handlers that drive a {Shutdown} coordinator, and
    # restores whatever was installed before on teardown.
    #
    # The trap bodies are PUSH-ONLY. Each does exactly one `sink.signal(symbol)`,
    # and the sink is a {Shutdown} (or another object satisfying its `#signal`
    # duck) whose body is a single async-signal-safe `write(2)` -- see
    # {Shutdown::Ingress} for why that one write, and nothing else, is the only
    # thing a deferred trap may safely do. No locks, no `Thread::Queue`, no fiber
    # operations run in the trap: reading the current sink is a plain ivar read,
    # and the sink's `#signal` is the pipe write.
    #
    # The sink is SWAPPABLE ({#route}): a chat installs the traps once for the
    # whole session, then points them at the fresh per-ask coordinator while a run
    # is in flight and back at a Null between asks. A signal with nothing routed
    # is dropped, which is exactly right -- there is no run to interrupt.
    class Signals
      # OS signal name -> the {Shutdown} input symbol it maps to. INT and TERM
      # open a grace window (or promote a second time); QUIT skips the countdown
      # and interrupts at once. HUP is a closed terminal and ends like TERM: left
      # at its default it kills the process before any ensure closes the record.
      MAP = { "INT" => :sigint, "TERM" => :sigterm, "HUP" => :sigterm, "QUIT" => :sigquit }.freeze

      # The absent-coordinator sink: between asks there is no run to stop, so a
      # signal is dropped. {Sink::Null}'s idiom -- the same `#signal` duck with
      # nothing behind it, so {#route} never needs a nil check.
      class Null
        def signal(_name) = self

        # Nothing is routed, so nothing a stop could reach.
        def ask_in_flight? = false
      end

      NULL = Null.new

      # The convenience form, for a caller with no Signals instance of its own
      # yet. A caller that already holds one ({CLI::Conductor} must keep
      # routing ITS instance for the ask's duration) calls {#guarding} directly.
      #
      # @param sink [#signal] the initial routing target
      def self.guarding(sink: NULL, &block)
        new(sink:).guarding(&block)
      end

      # @param sink [#signal] the current routing target; defaults to {NULL}
      def initialize(sink: NULL)
        @sink = sink
        @previous = {}
      end

      # Point the traps at a new sink. Plain assignment -- an in-flight trap
      # reads whichever sink is current, and a lost race (a signal landing on the
      # instant of a swap) is a dropped byte the coordinator's pipe already
      # tolerates.
      def route(sink)
        @sink = sink
        self
      end

      # This object is itself a sink, which is how a producer that is not an OS
      # trap reaches the same place the traps do: {Frontend::Intake} routes
      # here once and never again, and every later {#route} redirects the rail
      # WITH the traps rather than beside them, so the two cannot drift.
      def signal(name)
        @sink.signal(name)
        self
      end

      # The sink's other answer, asked by {Frontend::Intake} before it lifts
      # a `/stop` line off the rail as a signal: a line lifted while nothing is
      # routed would be dropped here and never seen again, which is worse than
      # any prompt's refusal of it. Read without a lock, like the sink itself,
      # so the whole question stays safe in trap context.
      def ask_in_flight? = @sink.ask_in_flight?

      # Install INT/TERM/HUP/QUIT, capturing each prior handler for {#uninstall}. The
      # trap body reads @sink at delivery time, so a later {#route} redirects
      # already-installed traps without reinstalling.
      def install
        MAP.each { |name, symbol| @previous[name] = Signal.trap(name) { @sink.signal(symbol) } }
        self
      end

      # Restore the handlers that were in force before {#install}. The teardown
      # order removes traps FIRST, then disposes the coordinator's pipe -- see
      # {Shutdown::Ingress#signal}'s ordering asterisk.
      def uninstall
        @previous.each { |name, handler| Signal.trap(name, handler) }
        @previous = {}
        self
      end

      # {#install}, yield self, {#uninstall} -- even on a raise. Both {.guarding}
      # and {CLI::Conductor#guard} delegate here, so the ordering is written in
      # exactly one place.
      def guarding
        install
        yield self
      ensure
        uninstall
      end
    end
  end
end
