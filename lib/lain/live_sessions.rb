# frozen_string_literal: true

require "async"

module Lain
  # The chats running now, as the daemon lists them, so another process can
  # find a chat's input socket and journal. A chat is listed while its
  # {Daemon::Registration} holds its connection open, so a crashed chat drops
  # out with the connection and nothing is left to reap.
  class LiveSessions
    include Enumerable

    UNLISTED = "cannot list the running chats: %<reason>s"

    # @param paths [Paths] names the runtime dir the daemon listens in
    # @param daemon [#call] answers a {Core::Client} or an {Daemon::Absent}; called once per listing
    # @param notes [#puts] told why a listing came back empty when the daemon failed it
    def initialize(paths:, daemon: -> { Daemon.ensure(paths:) }, notes: Sink::Null.new)
      @daemon = daemon
      @notes = notes
    end

    # @yieldparam record [Record] a listed chat, newest started_at first
    def each(&block)
      return enum_for(:each) unless block_given?

      listed.sort_by(&:started_at).reverse.each(&block)
    end

    # @param root [String] a checkout root
    # @return [Array<Record>] the attended live records for it
    def in(root) = select { |record| record.attended && record.root == root }

    private

    # A listing that fails is an empty one: whoever asked carries on as if no chat ran.
    def listed
      Sync do
        client = @daemon.call
        client.is_a?(Daemon::Absent) ? [] : read(client)
      end
    rescue StandardError => e
      @notes.puts(format(UNLISTED, reason: e.message))
      []
    end

    def read(client)
      client.call("session.list").map { |fields| Record.from_h(fields) }
    ensure
      client.stop
    end
  end
end
