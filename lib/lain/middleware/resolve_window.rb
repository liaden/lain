# frozen_string_literal: true

module Lain
  module Middleware
    # THE per-turn trigger that lets the run's window book stop being a guess.
    #
    # {CLI::Backend#context_window} is memoized, and it has to be: three readers
    # dividing by three different numbers is the failure that memo exists to
    # prevent. But a run launched with `--num-ctx` before its runner is resident
    # resolves to a GUESS ({CLI::Backend::WindowBook#book}), and a memo makes a
    # guess permanent -- the runner loads on turn one and the session goes on
    # measuring against a number nobody confirmed for as long as it runs.
    #
    # This is where the two are reconciled. The book's IDENTITY stays shared;
    # only its answer re-resolves, and only here, once on the way into each
    # turn. Doing it on every READ instead would be worse than never doing it:
    # {StatusFeed}, the compaction decision and the prompt line would each open
    # their own round trip and could see different windows within one turn,
    # which is precisely what the memo exists to prevent. Per-turn agreement is
    # the invariant; per-session immutability was only ever how it was bought.
    #
    # The book stops asking once its answer is authoritative
    # ({CLI::Backend::WindowBook::Live}), so this costs a settled run nothing
    # after the turn it settles on.
    #
    # OUTERMOST in the turn stack, ahead of {JournalTurns}: the refresh has to
    # land before anything downstream reads a window, and re-resolving is not
    # part of the turn a journal records.
    class ResolveWindow < Base
      # @param book [#reresolve] the run's one window book
      def initialize(book:)
        @book = book
        super()
        freeze
      end

      def call(env, &app)
        @book.reresolve
        downstream(env, &app)
      end
    end
  end
end
