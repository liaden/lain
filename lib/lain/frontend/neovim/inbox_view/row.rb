# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      class InboxView
        # One listed set, drawn. It draws and nothing else: no clock (the
        # INSTANT arrives resolved, so this object cannot race one), no store,
        # no lock. The width it fits a whole item against is the enclosing
        # view's {InboxView::WIDTH}, the buffer's own convention; the cut and
        # the wrap themselves are {Fold}'s, shared with {ApprovalView} rather
        # than one row's own; and the row inside them -- sender, age, question
        # -- is {Tools::AskHuman::InboxRow}'s, shared with the terminal's drain
        # so the two surfaces cannot name one question two ages.
        class Row
          # @param item [InboxView::Item] the listed set
          # @param now [Time] the instant this render is ageing against
          def initialize(item, now:)
            @item = item
            @now = now
          end

          # ONE LINE EXACTLY WHEN THAT LINE IS THE WHOLE ITEM. Anything else --
          # a question the announcement already cut, a set whose further
          # questions the summary only COUNTS, a row wider than {WIDTH} -- draws
          # the summary with its cut marked and the whole row underneath it,
          # indented, folded away at rest.
          #
          # NOTHING BOUNDS THE FOLD. {#whole} is built on EVERY render just to
          # decide this height, and it is the whole set: a 60KB question draws
          # ~655 indented lines, and {Question::Set::MAX_SET} permits roughly
          # 2800. {ApprovalView}'s precedent does not cover it, because a
          # command's `input.inspect` is incidentally short while
          # {Tools::AskHuman}'s own docstring INVITES tables and fenced diffs into
          # a question body. Three ways out, none free: clamp the body (loses the
          # verbatim guarantee {#whole} rests on), clamp only what is DRAWN while
          # the document keeps everything (two truths on one screen), or leave it
          # unbounded and let the fold hide it -- today, tolerable only because
          # the fold is closed at rest.
          # @return [Array<String>]
          def lines
            return [summary] if summary == whole && summary.length <= WIDTH

            [elided] + body
          end

          private

          # Sender and age lead, mirroring the TTY drain's listing: a glance
          # answers "who is stuck, and for how long" before the question reads.
          #
          # A summary must never OPEN with {INDENT}, which is why the `lstrip` is
          # here and is not tidying: that prefix is the runtime's whole test for a
          # continuation line, so a record naming NOBODY would draw a row the fold
          # surface reads as part of the item above it -- and the `<CR>` walk
          # would then answer that item's set.
          def summary = @summary ||= drawn(@item.question)

          # THE WHOLE ITEM, as one line before it is wrapped: the same sender
          # and age columns the summary shows, and every question the set asks
          # VERBATIM, rather than the announcement's one-line summary of them.
          #
          # THE INVARIANT, STATED AS NARROWLY AS IT IS TRUE: nothing the summary
          # elided is missing from the ITEM, because this line carries the whole
          # of it and {#lines} always draws this line when {#summary} is not it.
          # That is the safety property, and the only one worth relying on.
          #
          # It is NOT the stronger claim that the summary is a cut PREFIX of the
          # body. That holds for the common row and fails on two shapes. First,
          # any set of more than one question: the summary ends in
          # {Announcement}'s `(+N more)`, arithmetic that appears nowhere in the
          # body. Second, a body whose headline is not where the collapsed body
          # starts -- and a FENCED body is NOT that case, since the fence is the
          # first line and heads both renderings. What does it is the gap between
          # two definitions of "nothing": {Blankness} counts U+200B blank, so
          # {Announcement#headline} skips a line of it, while `String#strip`
          # removes only ASCII whitespace, so {#prose} keeps it. inbox_view_spec
          # pins both shapes, asserting the safety property AND asserting the
          # prefix relation is absent.
          #
          # THE SENDER AND AGE ARE REPEATED UNDER THE SUMMARY DELIBERATELY: the
          # body is the same row drawn the same way, so a reader comparing the
          # two lines is comparing like with like.
          def whole = @whole ||= drawn(questions)

          # EVERY FIELD THE RECORD SUPPLIES IS SCRUBBED, sender included: nvim
          # refuses a line holding a newline, the render rides as a NOTIFY, and
          # the buffer then silently stops taking writes. Scrubbing the sender
          # also makes the EDITOR more dependable -- `RECORD_START[INBOX]` and
          # 70_inbox.lua's `inbox_row` both find a row by the two-space-padded
          # `from  age  question` shape, which is why the padding and the
          # leading strip are the shared row's rather than this file's.
          def drawn(text)
            Tools::AskHuman::InboxRow.at(from: @item.from, summary: text, asked_at: @item.asked_at, now: @now).to_s
          end

          # Every question of the set, in the order it asks them.
          # {Tools::AskHuman} merges {Question::Set#to_body} into the event body
          # beside the one-line `"question"` summary, so the full prose is already
          # here. A body that is no set at all falls back to that summary.
          #
          # PERMISSIVE WHERE {Gestures#rebuilt} IS STRICT, deliberately: a
          # malformed set that cannot be OPENED must say so, while one that
          # cannot be fully DRAWN must still LIST -- a row that vanished would
          # hide a human's own pending question. Two readers of one wire shape is
          # a real smell; merging them is a bigger change.
          def questions
            listed = asked.filter_map { |question| question["body"] if question.is_a?(Hash) }
            joined = listed.map { |body| prose(body) }.join(" ")
            Blankness.blank?(joined) ? @item.question : joined
          end

          def asked
            listed = @item.body["questions"]
            listed.is_a?(Array) ? listed : []
          end

          # The scrub the shared row applies to a field, reached for HERE
          # because {#questions} joins several bodies into one string before
          # that row ever sees it. One spelling, so a body scrubbed on the way
          # into the join and the row scrubbed on the way out agree.
          def prose(text) = Tools::AskHuman::InboxRow.one_line(text)

          def elided = Fold.cut(summary)

          def body = Fold.wrap(whole)
        end
      end
    end
  end
end
