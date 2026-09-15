# frozen_string_literal: true

module Lain
  module Middleware
    # THE per-turn trigger that lets the run's window book stop being a guess.
    #
    # {CLI::Backend#context_window} is memoized because three readers dividing by
    # three different numbers is the failure that memo prevents. But a run
    # launched with `--num-ctx` before its runner is resident resolves to a GUESS
    # ({CLI::Backend::WindowBook#book}), and a memo makes a guess permanent.
    #
    # So the book's IDENTITY stays shared and only its answer re-resolves, once on
    # the way into each turn. Re-resolving on every READ would be worse than never
    # doing it: {StatusFeed}, the compaction decision and the prompt line could
    # each see a different window within one turn. Per-turn agreement is the
    # invariant; per-session immutability was only ever how it was bought. The
    # book stops asking once its answer is authoritative
    # ({CLI::Backend::WindowBook::Live}).
    #
    # OUTERMOST in the turn stack, ahead of {JournalTurns}: the refresh has to
    # land before anything downstream reads a window, and re-resolving is not part
    # of the turn a journal records.
    #
    # A prompt refused for not fitting the context raises through here, and the
    # refusal names the context the server loaded. That is a measured window, so
    # the book adopts it before the refusal goes on up; the turn still fails.
    class ResolveWindow < Base
      # @param book [#reresolve, #vouch] the run's one window book
      def initialize(book:)
        @book = book
        super()
        freeze
      end

      def call(env, &app)
        @book.reresolve
        downstream(env, &app)
      rescue Lain::WindowExceeded => e
        @book.vouch(e.window_tokens)
        raise
      end
    end
  end
end
