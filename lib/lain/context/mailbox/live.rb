# frozen_string_literal: true

require "securerandom"

module Lain
  class Context
    class Mailbox < Combinator
      # A running agent's inbox for notes a human types mid-run. {#post} only
      # queues, so the thread that took the line never touches the Store and
      # never waits on a record being written; the agent's own fiber writes
      # each note at {#capture}, at turn start, outside the lock.
      #
      # A note is pending while no turn on the CURRENT chain names it, whatever
      # it was addressed to. Its `to` is the chain as it stood when the note was
      # written, and a chain can move under a note: a stalled first prompt is
      # re-asked as a new root, and a rewind can drop the turn that folded one.
      # Either way no context that saw the note is left, so it folds again.
      # Only this inbox's own notes are judged, so an answer or a completion
      # addressed to the same chain never folds here.
      class Live
        # @param recipient [#call] `(timeline) -> String or nil`, the address a
        #   note gets; nil holds the queue until a chain exists
        # @param observer [#call] told each note as it is written, to record it
        def initialize(recipient:, observer:)
          @recipient = recipient
          @notes = Tools::Subagent::Log.new
          @writer = Event::ChainWriter.new(observer: lambda { |event|
            observer.call(event)
            @lock.synchronize { @notes << event }
          })
          @queue = []
          @posted = 0
          @nonce = SecureRandom.hex(8)
          @lock = Mutex.new
        end

        # {Event::ChainWriter#put} hashes no time, so the same words need the
        # sequence to stay apart within this inbox, and the nonce to stay apart
        # from an earlier inbox's notes on a resumed chain.
        #
        # @param from [String] who wrote the note
        # @param text [String]
        # @return [nil]
        def post(from:, text:)
          @lock.synchronize { @queue << { from:, body: body(text, @posted += 1) } }
          nil
        end

        # @param timeline [Timeline] the head this turn renders from
        # @return [Snapshot, Null] Null while nothing was ever posted, without
        #   walking the timeline
        def capture(timeline)
          return Null if never_posted?

          write_queued(timeline)
          Snapshot.new(pending: unconsumed(timeline, written))
        end

        # @param timeline [Timeline]
        # @return [Boolean] whether a note is queued or written but unconsumed
        def pending?(timeline)
          return false if never_posted?

          queued, notes = @lock.synchronize { [@queue.any?, @notes.to_a] }
          queued || unconsumed(timeline, notes).any?
        end

        private

        def body(text, sequence) = { "text" => text, "sequence" => sequence, "nonce" => @nonce }

        def never_posted? = @lock.synchronize { @posted.zero? }

        # One note at a time, each leaving the queue only once it is recorded,
        # so a failed write keeps it and every note behind it for the next
        # capture; the retry is idempotent on the Store. The record is written
        # outside the lock because its sinks can be slow, and only this fiber
        # ever removes from the queue, so the note it peeked is still first.
        def write_queued(timeline)
          to = @recipient.call(timeline)
          return if to.nil?

          note = first_queued
          until note.nil?
            write(timeline, to, note)
            note = first_queued
          end
        end

        def first_queued = @lock.synchronize { @queue.first }

        def write(timeline, to, note)
          @writer.put(timeline, kind: :message, to:, causal_parents: [], **note)
          @lock.synchronize { @queue.shift }
        end

        def written = @lock.synchronize { @notes.to_a }

        def unconsumed(timeline, notes)
          consumed = timeline.to_a.flat_map(&:causal_parents).to_set
          notes.reject { |note| consumed.include?(note.digest) }
        end
      end
    end
  end
end
