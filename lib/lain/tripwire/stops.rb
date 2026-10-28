# frozen_string_literal: true

module Lain
  module Tripwire
    # Who the tripwire has stopped, shared by the {Ledger} that trips it and
    # whatever later refuses a stopped requester's calls. A subagent's first
    # trip stops it and pauses main; a second trip by anyone, or main's own
    # first, stops every requester. So does a trip no record attributes, or one
    # under the name every unnamed subagent shares, since neither can be told
    # from main's or a second subagent's. A paused main
    # merges nothing and starts no new agent, but may still answer the other
    # subagents' questions.
    #
    # The Ledger trips this inside the Journal's monitor, and a reader asks it
    # before journaling a refusal, so it holds no journal at all: {#trip}
    # answers the outcome and the Ledger writes it.
    class Stops
      # The signals that may trip a stop, seeded by design and not yet measured;
      # every other signal stays observe-only. The stop fails closed: an honest
      # hook, nested toolchain or PATH search refused an exec trips it too.
      STOPPING = %w[refused_exec].freeze

      STOPPED = :stopped
      ALL_STOPPED = :all_stopped
      PAUSED = :paused
      FREE = :free

      # What a chat holds when the stop arm is off: no one is ever stopped.
      module None
        def self.standing(_requester) = FREE

        def self.first_tripped = nil

        def self.stopping(**) = Ledger::Stopping::Off
      end

      # @param main [Requester, String] the chat's own agent
      def initialize(main: Requester.main)
        @main = name_of(main)
        @lock = Mutex.new
        @tripped = Set.new
        @all = false
      end

      # @param requester [Requester, String]
      # @return [Symbol] {STOPPED} for a subagent's first trip, else {ALL_STOPPED}
      def trip(requester)
        name = name_of(requester)
        @lock.synchronize do
          @tripped.add(name)
          @all ||= [@main, *anonymous].include?(name) || @tripped.size > 1
          @all ? ALL_STOPPED : STOPPED
        end
      end

      # One read, so a trip landing between two separate reads cannot answer a mix of before and after.
      #
      # @param requester [Requester, String]
      # @return [Symbol] {STOPPED}, {PAUSED} or {FREE}
      def standing(requester)
        name = name_of(requester)
        @lock.synchronize do
          if @all || @tripped.include?(name) then STOPPED
          elsif name == @main && @tripped.any? then PAUSED
          else FREE
          end
        end
      end

      # @param rules [Rules]
      # @return [Ledger::Stopping] the half of a ledger that trips these stops
      def stopping(rules:) = Ledger::Stopping.new(stops: self, rules:)

      # @return [String, nil] the requester that tripped first, nil before any trip
      def first_tripped = @lock.synchronize { @tripped.first }

      private

      # Names no single agent answers to: a trip under one could be any agent, main included.
      def anonymous = [Ledger::UNKNOWN, Requester::UNNAMED.name]

      def name_of(requester) = requester.is_a?(Requester) ? requester.name : requester.to_s
    end
  end
end
