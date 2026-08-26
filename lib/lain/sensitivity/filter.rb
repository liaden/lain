# frozen_string_literal: true

module Lain
  class Sensitivity
    # The classifier's answer applied to a LIST: which rows of a result the
    # model may see, and how many were taken away. {Policy} asks the same
    # classifier whether a CALL may happen, before the tool runs; this runs
    # after, over the rows it produced. The count rides along because silent
    # truncation reads as "that is everything", which is a lie the agent acts on.
    #
    # == A row has READINGS, not a path
    #
    # The caller supplies every path a row could name, and a row is withheld
    # when ANY of them is not ordinary. A colon is legal in a path, so grep's
    # `file:line:text` has no unambiguous split: `odd:1/.env:1:API_KEY=...`
    # reads as `odd`, which is ordinary, and as `odd:1/.env`, which is not.
    # Judging one reading means picking which to be wrong about; judging all of
    # them means a sensitive reading always wins.
    #
    # A row with NO readings is kept -- the one deliberate fail-open, for grep's
    # `... capped at 200 matches` trailer, which names no file. It is safe only
    # because a reader that cannot parse a row returns no reading rather than a
    # wrong one.
    #
    # == Not ordinary, rather than gated
    #
    # {Verdict#gated?} is false for a DENIED path, so a filter asking that
    # question would list `~/.ssh/id_rsa` while withholding `.env`. Anything the
    # classifier does not call ordinary is withheld -- {MALFORMED} included,
    # because a row nobody can parse is a row nobody can vouch for.
    class Filter
      Sifted = Data.define(:kept, :withheld)

      # What one sifting decided: the rows that survived, and the verdict that
      # took each row that did not. The verdicts ride whole rather than
      # collapsed to a count, for {Denial}'s reason: `:protected` and
      # `:configured` are different findings, and reporting a project's own rule
      # as ours makes "why was my file withheld?" unanswerable.
      class Sifted
        def any? = withheld.any?
        def count = withheld.length

        # Sorted rather than in encounter order: the two grep paths do not
        # agree on walk order (`tools/grep.rb`), so one listing reported twice
        # would otherwise read differently each time.
        def reasons = withheld.map(&:reason).uniq.sort
      end

      # Withholds nothing, so a run that resolved no project root produces
      # byte-identical listings and no caller writes `if filter`. A shared
      # frozen instance for {Policy::Null}'s reason: a fresh one per default
      # would make two otherwise identical guards compare unequal.
      class Null
        def sift(rows) = Sifted.new(kept: rows.to_a, withheld: [])

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # @param sensitivity [Sensitivity] the classifier, injected -- its home,
      #   cwd and project rules are all somebody else's to resolve
      # @raise [ArgumentError] on a nil classifier
      def initialize(sensitivity:)
        # A missing KEYWORD is Ruby's error; a nil VALUE is not, and a filter
        # answering "nothing sensitive here" to a half-finished wiring is a
        # withholding control that withholds nothing, wearing this codebase's
        # Null idiom as camouflage. {Null} is the way to mean it.
        raise ArgumentError, "a classifier is required: pass #{Null.name} where a run withholds nothing" \
          unless sensitivity

        @sensitivity = sensitivity
        freeze
      end

      # @param rows [Enumerable<String>] the result's rows, in the tool's order
      # @yieldparam row [String] one row
      # @yieldreturn [Array<String>] every path that row could name
      # @return [Sifted]
      def sift(rows)
        judged = rows.map { |row| [row, verdict_for(yield(row))] }
        kept, hidden = judged.partition { |_row, verdict| verdict.nil? }
        Sifted.new(kept: kept.map(&:first), withheld: hidden.map(&:last))
      end

      private

      # The first reading of this row that is not ordinary, and nil when every
      # reading is. Lazy, so an early sensitive reading stops the walk -- and so
      # the verdict reported is the first one found rather than the last.
      def verdict_for(readings)
        readings.lazy.map { @sensitivity.classify(_1) }.find { !_1.ordinary? }
      end
    end
  end
end
