# frozen_string_literal: true

require "async"

module Lain
  module Daemon
    # Keeps 1 chat in the daemon's session list for as long as the chat runs,
    # which is what lets the review queue and the phone find it. The daemon
    # drops a session when its connection closes, so the connection is the
    # registration: a lost one is reconnected and registered again, and only
    # then are the new connection's pushes handed on.
    #
    # A reconnect only attaches to whatever daemon answers, starting one when
    # none does: 2 checkouts sharing a runtime dir would otherwise each replace
    # the other's daemon, and each replacement would send the other back here.
    class Registration
      # The event a subscriber hears once a lost connection is registered again.
      RECONNECTED = :reconnected
      FIRST_DELAY = 0.5
      LONGEST_DELAY = 30.0
      DOUBLINGS = 6
      # Failures in a row before the human hears that the daemon is gone.
      PATIENCE = 3
      SLEEP = ->(seconds) { Async::Task.current.sleep(seconds) }
      UNFOUND = "the review queue cannot find this chat"
      LOST = "lost the daemon (%<reason>s); still trying to register this chat"
      FAILED = "a %<method>s subscriber failed: %<reason>s"
      UNHEARD = ->(_params) {}

      # A method already has the 1 subscriber it may have.
      class Taken < Error; end

      # There is no daemon to come back to, so a lost connection is not retried.
      class Gone < Error; end

      # What a session holds when no daemon is there to register with.
      class Null
        # @return [nil]
        def open(_task) = nil

        # @return [nil]
        def close = nil

        # @return [nil]
        def call(*) = nil

        # @return [nil]
        def on(*) = nil
      end

      # @param record [LiveSessions::Record] what the chat says about itself
      # @param daemon [#call] takes `pushes:` and `replace:` and answers a {Core::Client} or an
      #   {Absent}, as {Daemon.ensure} does
      # @param notes [#puts] told when the chat cannot be registered, or has lost the daemon for a while
      # @param sleeper [#call] waits the seconds it is given between reconnect attempts
      def initialize(record:, daemon:, notes:, sleeper: SLEEP)
        @record = record
        @daemon = daemon
        @notes = notes
        @sleeper = sleeper
        @subscribers = {}
        @client = nil
        @keeper = nil
      end

      # Registers before it returns. The daemon refuses a process whose parent
      # chain reaches a registered chat, so a child that registers after this
      # cannot take the chat's place.
      # @param task [Async::Task] the chat's own, which the reconnects run under
      # @return [self]
      def open(task)
        pushes = Async::Queue.new
        @client = registered(pushes, replace: true)
        @keeper = task.async { keep(pushes) }
        self
      rescue StandardError => e
        unfound(e)
        self
      end

      # @return [nil]
      def close
        @keeper&.stop
        @client&.stop
        @client = nil
      end

      # @param method [String]
      # @param params [Array] the request's params
      # @return [Object, nil] the daemon's answer; nil when there is no daemon
      def call(method, *params) = @client&.call(method, params)

      # @param method [String, Symbol] a pushed method, or {RECONNECTED}
      # @yieldparam params [Array] the push's params; empty for {RECONNECTED}
      # @return [self]
      # @raise [Taken] when the method has a subscriber already
      def on(method, &handler)
        raise Taken, "#{method} already has a subscriber" if @subscribers.key?(method)

        @subscribers[method] = handler
        self
      end

      private

      def keep(pushes)
        while pushes
          served(pushes)
          pushes = reconnected
        end
      rescue StandardError => e
        unfound(e)
      end

      def served(pushes)
        delivering = Async { pushes.each { |method, params| deliver(method, params) } }
        @client.wait
      ensure
        pushes.close
        delivering&.wait
      end

      # Absent and a refused registration end the keeping: there is no daemon
      # to come back to, or it will not have this chat.
      def reconnected
        @client = nil
        pushes = Async::Queue.new
        attempt = 0
        @client = attempted(pushes, attempt += 1) until @client
        deliver(RECONNECTED, [])
        pushes
      rescue Gone, Core::Client::Refused => e
        unfound(e)
      end

      def attempted(pushes, attempt)
        registered(pushes, replace: false)
      rescue Gone, Core::Client::Refused
        raise
      rescue StandardError => e
        @notes.puts(format(LOST, reason: e.message)) if attempt == PATIENCE
        @sleeper.call([FIRST_DELAY * (2**[attempt - 1, DOUBLINGS].min), LONGEST_DELAY].min)
        nil
      end

      def registered(pushes, replace:)
        client = @daemon.call(pushes:, replace:)
        raise Gone, client.reason if client.is_a?(Absent)

        client.call("session.register", [@record.to_h])
        client
      rescue Core::Client::Refused
        client&.stop
        raise
      end

      def deliver(method, params)
        @subscribers.fetch(method, UNHEARD).call(params)
      rescue StandardError => e
        @notes.puts(format(FAILED, method:, reason: e.message))
      end

      # With no daemon, the start already said why on the same notes.
      def unfound(error)
        @notes.puts(error.is_a?(Gone) ? UNFOUND : "#{UNFOUND}: #{error.message}")
        nil
      end
    end
  end
end
